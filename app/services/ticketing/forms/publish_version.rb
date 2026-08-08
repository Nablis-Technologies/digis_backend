# frozen_string_literal: true

require "digest"

module Ticketing
  module Forms
    # Publishes one validated draft and retires its prior published sibling in a
    # single transaction. The audit key and request digest make retried publish
    # requests idempotent without accepting a different request under one key.
    class PublishVersion < Core::BaseService
      def initialize(version:, actor:, idempotency_key: nil)
        @version = version
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        @idempotency_key_digest = Core::IdempotencyKey.new(idempotency_key).digest
        ActiveRecord::Base.transaction do
          form = Ticketing::RegistrationForm.includes(:event).lock.find(version.registration_form_id)
          return failure(not_authorized_error) unless authorized?(form)
          requested = locked_version(form, version.id)
          published = published_version(form)

          return failure(not_found_error) unless requested
          request_digest = request_digest_for(requested)
          return success(requested) if replayed?(request_digest)
          if requested.published?
            record_audit(
              requested,
              request_digest,
              action: "ticketing.registration_form_version.publish_requested",
              audited_changes: { status: [ requested.status, requested.status ] }
            )
            return success(requested)
          end
          return failure(not_draft_error) unless requested.status == "draft"

          draft = requested

          validation_error = question_validation_error(draft)
          return failure(validation_error) if validation_error

          # A form has one live schema: retire the old version before exposing
          # the new immutable version.
          published.update!(status: "retired") if published && published.id != draft.id
          draft.update!(
            status: "published",
            published_by: actor,
            published_at: Time.current
          )
          record_audit(
            draft,
            request_digest,
            action: "ticketing.registration_form_version.published",
            audited_changes: { status: [ "draft", "published" ] }
          )

          success(draft)
        end
      rescue ArgumentError => error
        failure invalid_idempotency_key_error(error.message)
      rescue Core::Audit::Record::ReplayConflict
        failure idempotency_conflict_error
      rescue ActiveRecord::RecordInvalid => error
        failure invalid_version_error(error.record)
      end

      private

      attr_reader :version, :actor, :idempotency_key, :idempotency_key_digest

      def locked_version(form, version_id)
        Ticketing::RegistrationFormVersion
          .where(id: version_id, registration_form_id: form.id)
          .includes(:questions, :registration_form)
          .lock
          .first
      end

      def published_version(form)
        Ticketing::RegistrationFormVersion
          .where(registration_form_id: form.id, status: "published")
          .includes(:questions, :registration_form)
          .lock
          .first
      end

      def not_found_error
        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.version_not_found"),
          code: "version_not_found",
          status: :not_found
        )
      end

      def authorized?(form)
        Events::AuthorizationResolver.can_manage_catalog?(actor, form.event)
      end

      def not_authorized_error
        Core::BusinessError.new(
          I18n.t("authorization.errors.unauthorized"),
          code: "not_authorized",
          status: :forbidden
        )
      end

      def not_draft_error
        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.version_not_draft"),
          code: "version_not_draft",
          status: :unprocessable_entity
        )
      end

      def question_validation_error(draft)
        questions = if draft.association(:questions).loaded?
          draft.association(:questions).target.sort_by(&:position)
        else
          draft.questions.order(:position).to_a
        end
        invalid_questions = questions.each_with_object({}) do |question, errors|
          question.registration_form_version = draft
          next if question.valid?

          errors[question.key.presence || question.id] = question.errors.to_hash
        end
        return if invalid_questions.empty?

        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.invalid_form_version"),
          code: "invalid_form_version",
          status: :unprocessable_entity,
          errors: { questions: invalid_questions }
        )
      end

      def invalid_version_error(record)
        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.invalid_form_version"),
          code: "invalid_form_version",
          status: :unprocessable_entity,
          errors: record.errors.to_hash
        )
      end

      def request_digest_for(published_version)
        payload = {
          action: "publish",
          version_id: published_version.id.to_s,
          actor_id: actor.id.to_s
        }
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(payload))
      end

      def audit_key
        "ticketing-registration-form-version-publish-#{idempotency_key_digest}"
      end

      def replayed?(request_digest)
        audit = Core::AuditLog.lock.find_by(audit_key: audit_key)
        return false unless audit

        return true if audit.metadata.deep_symbolize_keys[:request_digest] == request_digest

        raise Core::Audit::Record::ReplayConflict
      end

      def record_audit(published_version, request_digest, action:, audited_changes:)
        Core::Audit::Record.call(
          audit_key:,
          action:,
          auditable_type: published_version.class.name,
          auditable_id: published_version.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes:,
          metadata: {
            registration_form_id: published_version.registration_form_id,
            version_id: published_version.id,
            version: published_version.version,
            idempotency_key_digest: idempotency_key_digest,
            request_digest:
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

      def idempotency_conflict_error
        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.idempotency_conflict"),
          code: "idempotency_conflict",
          status: :unprocessable_entity
        )
      end
    end
  end
end
