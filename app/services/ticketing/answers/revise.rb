# frozen_string_literal: true

require "digest"

module Ticketing
  module Answers
    # Appends a corrected answer without overwriting the original response.
    # A locked answer plus idempotency/request digests serialize revisions and
    # make a client retry return its original correction evidence.
    class Revise < Core::BaseService
      def initialize(answer:, revised_by:, value:, source:, reason_code: nil, idempotency_key:)
        @answer = answer
        @revised_by = revised_by
        @value = value
        @source = source.to_s
        @reason_code = reason_code&.to_s
        @idempotency_key = idempotency_key
      end

      def call
        @idempotency_key_digest = Core::IdempotencyKey.new(idempotency_key).digest
        revision = nil

        ActiveRecord::Base.transaction do
          locked_answer = Ticketing::RegistrationAnswer
            .where(id: answer.id)
            .includes(
              :revisions,
              :registration_question,
              registration_form_submission: { registration: [ :ticket_type, :event ] }
            )
            .lock
            .first
          return failure(invalid_revision_error(answer)) unless locked_answer

          return failure(not_authorized_error) unless authorized?(locked_answer)

          validation = validate_value(locked_answer)
          return failure(invalid_value_error(validation.error.code)) if validation.failure?
          normalized_value = validation.value.first&.fetch(:value, nil)
          @request_digest = request_digest_for(normalized_value)

          # Check the idempotency boundary before mutable business windows so a
          # valid retry remains successful after the correction window closes.
          existing = Ticketing::RegistrationAnswerRevision
            .where(idempotency_key_digest: idempotency_key_digest)
            .lock
            .first
          return replay_result(existing, locked_answer, @request_digest) if existing

          return failure(answer_erased_error) if locked_answer.erased?
          return failure(retention_expired_error) if retention_expired?(locked_answer)
          return failure(correction_window_closed_error) if correction_window_closed?(locked_answer)

          revision = locked_answer.revisions.build(
            revision_number: next_revision_number(locked_answer),
            revised_by: revised_by,
            source: source,
            reason_code: reason_code,
            idempotency_key_digest: idempotency_key_digest,
            request_digest: @request_digest,
            revised_at: Time.current
          )
          revision.answer = normalized_value
          return failure(invalid_revision_error(revision)) unless revision.valid?

          revision.save!
          record_audit(revision, locked_answer)
        end

        success(revision)
      rescue ArgumentError => error
        failure invalid_idempotency_key_error(error.message)
      rescue ActiveRecord::RecordInvalid => error
        failure invalid_revision_error(error.record)
      rescue ActiveRecord::RecordNotUnique
        existing = Ticketing::RegistrationAnswerRevision.find_by(idempotency_key_digest: idempotency_key_digest)
        if existing
          return replay_result(existing, answer, @request_digest)
        end

        failure(revision_conflict_error)
      end

      private

      attr_reader :answer, :revised_by, :value, :source, :reason_code, :idempotency_key,
                  :idempotency_key_digest

      def next_revision_number(answer_record)
        Ticketing::RegistrationAnswerRevision
          .where(registration_answer_id: answer_record.id)
          .maximum(:revision_number).to_i + 1
      end

      def validate_value(answer_record)
        question = answer_record.registration_question
        registration = answer_record.registration_form_submission.registration
        Ticketing::Forms::ValidateSubmission.call(
          schema: [ question ],
          submission: {
            package_quantity: registration.package_quantity,
            admissions_per_unit: registration.admissions_per_unit_snapshot,
            answers: [
              {
                question_key: question.key,
                package_unit_number: answer_record.package_unit_number,
                admission_position: answer_record.admission_position,
                value:
              }
            ]
          }
        )
      end

      def retention_expired?(answer_record)
        answer_record.retain_until.present? && Time.current >= answer_record.retain_until
      end

      def authorized?(answer_record)
        event = answer_record.registration_form_submission.registration.event
        return Events::AuthorizationResolver.can_manage_catalog?(revised_by, event) if source == "manager_correction"

        registration = answer_record.registration_form_submission.registration
        registration.user_id == revised_by.id
      end

      def correction_window_closed?(answer_record)
        return false unless source == "attendee_correction"

        registration = answer_record.registration_form_submission.registration
        cutoff = Ticketing::Answers::CorrectionWindow.call(registration:)
        cutoff.present? && Time.current > cutoff
      end

      def replay_result(existing, answer_record, request_digest)
        return success(existing) if same_request?(existing, answer_record, request_digest)

        failure(revision_conflict_error)
      end

      def same_request?(existing, answer_record, request_digest)
        existing.registration_answer_id == answer_record.id &&
          existing.request_digest == request_digest
      end

      def request_digest_for(normalized_value)
        payload = {
          answer_id: answer.id.to_s,
          revised_by_id: revised_by.id.to_s,
          source:,
          reason_code:,
          value: RegistrationAnswer.canonical_value(normalized_value)
        }
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(payload))
      end

      def record_audit(revision, answer_record)
        Core::Audit::Record.call(
          audit_key: "ticketing-registration-answer-revision-#{revision.id}",
          action: "ticketing.registration_answer.revised",
          auditable_type: answer_record.class.name,
          auditable_id: answer_record.id,
          actor_type: revised_by.class.name,
          actor_id: revised_by.id,
          metadata: {
            revision_id: revision.id,
            revision_number: revision.revision_number,
            source: revision.source,
            reason_code: revision.reason_code,
            idempotency_key_digest: revision.idempotency_key_digest,
            request_digest: revision.request_digest
          }
        )
      end

      def invalid_idempotency_key_error(message)
        Core::BusinessError.new(
          message,
          code: "invalid_idempotency_key",
          status: :unprocessable_entity
        )
      end

      def answer_erased_error
        Core::BusinessError.new(
          I18n.t("ticketing.answers.errors.answer_erased"),
          code: "answer_erased",
          status: :unprocessable_entity
        )
      end

      def revision_conflict_error
        Core::BusinessError.new(
          I18n.t("ticketing.answers.errors.revision_conflict"),
          code: "revision_conflict",
          status: :unprocessable_entity
        )
      end

      def retention_expired_error
        Core::BusinessError.new(
          I18n.t("ticketing.answers.errors.retention_expired"),
          code: "retention_expired",
          status: :unprocessable_entity
        )
      end

      def not_authorized_error
        Core::BusinessError.new(
          I18n.t("authorization.errors.unauthorized"),
          code: "not_authorized",
          status: :forbidden
        )
      end

      def correction_window_closed_error
        Core::BusinessError.new(
          I18n.t("ticketing.answers.errors.correction_window_closed"),
          code: "correction_window_closed",
          status: :unprocessable_entity
        )
      end

      def invalid_revision_error(record)
        Core::BusinessError.new(
          I18n.t("ticketing.answers.errors.invalid_answer_revision"),
          code: "invalid_answer_revision",
          status: :unprocessable_entity,
          errors: record.respond_to?(:errors) ? record.errors.to_hash : nil
        )
      end

      def invalid_value_error(code)
        Core::BusinessError.new(
          I18n.t("ticketing.answers.errors.invalid_answer_revision"),
          code: "invalid_answer_revision",
          status: :unprocessable_entity,
          errors: { value: [ code ] }
        )
      end
    end
  end
end
