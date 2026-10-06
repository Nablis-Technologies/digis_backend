# frozen_string_literal: true

module Ticketing
  module Registrations
    # Completes the Ticketing-side gift registration. The caller validates its
    # commerce source first; this command remains independent of Orders models.
    class CompleteGift < Core::BaseService
      def initialize(registration:, actor:, submission:, idempotency_key:, at: Time.current)
        @registration_id = registration.id
        @actor = actor
        @submission = submission
        @raw_idempotency_key = idempotency_key
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(error("gift_claim_invalid")) if @initialization_error

        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        request_digest = request_digest_for(key)
        audit_key = "ticketing-gift-registration-completed-#{@registration_id}-#{key.digest}"
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        outcome = nil
        ActiveRecord::Base.transaction do
          registration = Ticketing::Registration.includes(
            :user,
            :consent_requirements,
            :event,
            ticket_type: { event_product: :event }
          )
            .lock.find(@registration_id)
          event = Events::Event.lock.find(registration.event_id)
          validation = validate(registration:, event:)
          if validation
            outcome = failure(validation)
            raise ActiveRecord::Rollback
          end

          schema = Ticketing::Forms::ApplicableSchema.call(
            event:,
            ticket_type: registration.ticket_type
          )
          if schema.failure?
            outcome = failure(schema.error)
            raise ActiveRecord::Rollback
          end

          normalized_submission = recipient_submission(registration)
          skip_forms = registration.form_submissions.exists? && normalized_submission.answers.blank?
          unless skip_forms || schema.value.empty?
            forms = Ticketing::Forms::PersistSubmission.call(
              registration:,
              schema: schema.value,
              submission: normalized_submission.to_h,
              actor: @actor
            )
            if forms.failure?
              outcome = failure(forms.error)
              raise ActiveRecord::Rollback
            end
          end

          consents = Ticketing::Consent::BuildRequirements.call(
            registration:,
            acceptances: normalized_submission.consents,
            actor: @actor,
            allow_unverified: true
          )
          if consents.failure?
            outcome = failure(consents.error)
            raise ActiveRecord::Rollback
          end

          previous_status = registration.status
          registration.update!(status: "confirmed", confirmed_at: registration.confirmed_at || @at, next_action_snapshot: nil)
          record_completion!(registration, key, audit_key, request_digest, previous_status)
          outcome = success(registration.reload)
        end
        outcome
      rescue ArgumentError
        failure(error("invalid_idempotency_key"))
      rescue ActiveRecord::RecordNotFound
        failure(error("gift_claim_invalid", status: :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error("gift_claim_invalid", errors: exception.record.errors.to_hash))
      rescue Core::Audit::Record::ReplayConflict
        failure(error("idempotency_conflict", status: :conflict))
      end

      private

      def validate(registration:, event:)
        return error("event_cancelled", status: :conflict) if event.status == "cancelled"
        return error("gift_claim_invalid", status: :conflict) unless registration.event_id == event.id
        return error("gift_recipient_mismatch", status: :forbidden) unless
          @actor.is_a?(Core::User) && registration.user_id == @actor.id
        return error("gift_registration_not_pending", status: :conflict) unless
          registration.status == "gift_pending_claim" ||
          (registration.status == "confirmed" && registration.consent_requirements.any? { |r| r.required? && r.pending? })

        nil
      end

      def recipient_submission(registration)
        submitted = @submission.respond_to?(:to_h) ? @submission.to_h.deep_symbolize_keys : {}
        Ticketing::RegistrationSubmission.new(
          package_quantity: registration.package_quantity,
          selected_event_date_id: registration.selected_event_date_id,
          answers: submitted[:answers],
          consents: submitted[:consents]
        )
      end

      def request_digest_for(key)
        submitted = @submission.respond_to?(:to_h) ? @submission.to_h.deep_symbolize_keys : {}
        input_digest = Core::KeyedDigest.digest(
          namespace: "ticketing-gift-form-input:#{@registration_id}",
          value: ActiveSupport::JSON.encode(canonical(submitted.slice(:answers, :consents)))
        )
        Core::KeyedDigest.digest(
          namespace: "ticketing-gift-registration-completion:#{@registration_id}",
          value: [ @registration_id, @actor&.id, key.digest, input_digest ].join(":")
        )
      end

      def replay_result(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit
        return failure(error("idempotency_conflict", status: :conflict)) unless
          audit.metadata["request_digest"] == request_digest

        success(Ticketing::Registration.find(@registration_id))
      rescue ActiveRecord::RecordNotFound
        failure(error("gift_claim_invalid", status: :not_found))
      end

      def record_completion!(registration, key, audit_key, request_digest, previous_status = "gift_pending_claim")
        result = Core::Audit::Record.call(
          audit_key:,
          action: "ticketing.registration.gift_completed",
          auditable_type: registration.class.name,
          auditable_id: registration.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { status: [ previous_status, "confirmed" ] },
          metadata: {
            event_id: registration.event_id,
            idempotency_key_digest: key.digest,
            request_digest:
          }
        )
        raise result.error if result.failure?
      end

      def canonical(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonical(nested) }
        when Array
          value.map { |nested| canonical(nested) }
        else
          value.as_json
        end
      end

      def error(key, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.gift_purchases.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
