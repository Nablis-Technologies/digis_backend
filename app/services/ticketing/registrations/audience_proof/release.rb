# frozen_string_literal: true

module Ticketing
  module Registrations
    module AudienceProof
      # Returns consumed audience proof as part of a caller's terminal
      # registration transaction. The transition key makes audit replay safe.
      class Release < Core::BaseService
        def initialize(registration:, reason:, transition_key:, at: Time.current)
          @registration_id = registration.id
          @reason = reason.to_s
          @transition_digest = Ticketing::Registrations::AudienceProof::Support.transition_digest(transition_key)
          raise ArgumentError if @transition_digest.blank?
          @at = at.to_time.utc
        rescue ArgumentError, NoMethodError => error
          @initialization_error = error
        end

        def call
          return failure(invalid_transition_key) if @initialization_error

          Registration.transaction do
            registration = Registration.lock.includes(:ticket_type, :access_code, :invitation).find(@registration_id)
            audit_key = release_audit_key(registration)
            next success(registration) if Core::AuditLog.exists?(audit_key:)

            proof_kind, proof = Ticketing::Registrations::AudienceProof::Support
              .proof_reference(registration:)
            next success(registration) if proof_kind == :public

            proof_type, proof_id = case proof_kind
            when :access_code then release_access_code!(registration, proof)
            when :invitation then release_invitation!(registration, proof)
            else
              inconsistent!
            end
            record_release!(registration, audit_key:, proof_type:, proof_id:)
            success(registration)
          end
        rescue Ticketing::Registrations::Support::Halt => error
          error.result
        rescue Core::Error => error
          failure(error)
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
          failure(release_inconsistent)
        end

        private

        def release_access_code!(registration, code)
          locked = Ticketing::AccessCode.lock.find_by(
            id: code.id, ticket_type_id: registration.ticket_type_id
          )
          inconsistent! unless locked && locked.used_count >= registration.package_quantity

          locked.update!(used_count: locked.used_count - registration.package_quantity)
          [ "access_code", locked.id ]
        end

        def release_invitation!(registration, invitation)
          locked = Ticketing::Invitation.lock.find_by(
            id: invitation.id, ticket_type_id: registration.ticket_type_id
          )
          inconsistent! unless locked
          return [ "invitation", locked.id ] if locked.status.in?(%w[expired revoked])
          inconsistent! unless locked.status == "accepted" && locked.invited_user_id == registration.user_id

          next_status = locked.expires_at.present? && locked.expires_at <= @at ? "expired" : "pending"
          locked.update!(status: next_status, accepted_at: nil)
          [ "invitation", locked.id ]
        end

        def record_release!(registration, audit_key:, proof_type:, proof_id:)
          result = Core::Audit::Record.call(
            audit_key:,
            action: "ticketing.registration.audience_proof_released",
            auditable_type: "Ticketing::Registration",
            auditable_id: registration.id,
            audited_changes: { proof_state: "released" },
            metadata: {
              registration_id: registration.id,
              proof_type:,
              proof_record_id: proof_id,
              quantity: registration.package_quantity,
              transition_reason: @reason
            }
          )
          raise result.error if result.failure?
        end

        def release_audit_key(registration)
          "ticketing-registration-audience-proof-release-#{registration.id}-#{@transition_digest}"
        end

        def inconsistent!
          raise Ticketing::Registrations::Support::Halt, failure(release_inconsistent)
        end

        def release_inconsistent
          Core::BusinessError.new(
            I18n.t("ticketing.registration_workflows.errors.audience_proof_release_inconsistent"),
            code: "audience_proof_release_inconsistent",
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
