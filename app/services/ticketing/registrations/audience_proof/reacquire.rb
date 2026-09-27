# frozen_string_literal: true

module Ticketing
  module Registrations
    module AudienceProof
      # Reacquires the registration's previously associated proof when an
      # organizer reconsiders a rejected registration.
      class Reacquire < Core::BaseService
        def initialize(registration:, transition_key:, at: Time.current)
          @registration_id = registration.id
          @transition_digest = Ticketing::Registrations::AudienceProof::Support.transition_digest(transition_key)
          raise ArgumentError if @transition_digest.blank?
          @at = at.to_time.utc
        rescue ArgumentError, NoMethodError => error
          @initialization_error = error
        end

        def call
          return failure(invalid_transition_key) if @initialization_error

          Registration.transaction do
            registration = Registration.lock
              .includes(:ticket_type, :user, :access_code, :invitation)
              .find(@registration_id)
            audit_key = reacquire_audit_key(registration)
            next success(registration) if Core::AuditLog.exists?(audit_key:)

            proof_kind, proof = Ticketing::Registrations::AudienceProof::Support
              .proof_reference(registration:)
            next success(registration) if proof_kind == :public

            proof_type, proof_id = case proof_kind
            when :access_code then reacquire_access_code!(registration, proof)
            when :invitation then reacquire_invitation!(registration, proof)
            else
              unavailable!
            end
            record_reacquisition!(registration, audit_key:, proof_type:, proof_id:)
            success(registration)
          end
        rescue Ticketing::Registrations::Support::Halt => error
          error.result
        rescue Core::Error => error
          failure(error)
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
          failure(proof_unavailable)
        end

        private

        def reacquire_access_code!(registration, access_code)
          result = Ticketing::AccessCodes::Consume.call(
            ticket_type: registration.ticket_type,
            access_code:,
            quantity: registration.package_quantity,
            at: @at
          )
          abort_with(result) if result.failure?
          [ "access_code", result.value.id ]
        end

        def reacquire_invitation!(registration, invitation)
          result = Ticketing::Invitations::Claim.call(
            ticket_type: registration.ticket_type,
            invitation:,
            user: registration.user,
            quantity: registration.package_quantity,
            at: @at
          )
          abort_with(result) if result.failure?
          [ "invitation", result.value.id ]
        end

        def record_reacquisition!(registration, audit_key:, proof_type:, proof_id:)
          result = Core::Audit::Record.call(
            audit_key:,
            action: "ticketing.registration.audience_proof_reacquired",
            auditable_type: "Ticketing::Registration",
            auditable_id: registration.id,
            audited_changes: { proof_state: "reacquired" },
            metadata: {
              registration_id: registration.id,
              proof_type:,
              proof_record_id: proof_id,
              quantity: registration.package_quantity,
              transition_reason: "organizer_reconsideration"
            }
          )
          raise result.error if result.failure?
        end

        def reacquire_audit_key(registration)
          "ticketing-registration-audience-proof-reacquired-#{registration.id}-#{@transition_digest}"
        end

        def abort_with(result)
          raise Ticketing::Registrations::Support::Halt, result
        end

        def unavailable!
          raise Ticketing::Registrations::Support::Halt, failure(proof_unavailable)
        end

        def proof_unavailable
          Core::BusinessError.new(
            I18n.t("ticketing.registration_workflows.errors.audience_proof_unavailable"),
            code: "audience_proof_unavailable",
            status: :conflict
          )
        end

        def invalid_transition_key
          Core::BusinessError.new(
            I18n.t("ticketing.registration_workflows.errors.invalid_idempotency_key"),
            code: "invalid_idempotency_key",
            status: :bad_request
          )
        end
      end
    end
  end
end
