# frozen_string_literal: true

require "set"

module Ticketing
  class CredentialClaims
    # Accepts a claim only for its authenticated recipient. Slot ownership and
    # QR/PNR/index activation are committed together, and remain pending when
    # a personal registration requirement is still open.
    class Accept < Core::BaseService
      Result = Data.define(:claim, :credential)

      def initialize(token:, actor:)
        @token = token
        @actor = actor
      end

      def call
        outcome = nil
        Ticketing::CredentialClaim.transaction do
          claim = Ticketing::CredentialClaim.lock.find_by(
            token_digest: Ticketing::CredentialClaim.token_digest_for(token: @token)
          )
          unless claim
            outcome = failure(error(:claim_invalid, :not_found))
            raise ActiveRecord::Rollback
          end

          claim.with_lock do
            if claim.status == "accepted"
              outcome = replay(claim)
              raise ActiveRecord::Rollback
            end
            validation = validate_claim(claim)
            if validation
              outcome = failure(validation)
              raise ActiveRecord::Rollback
            end

            credential = load_credential(claim)
            ticket = credential.ticket
            if credential.status != "pending_claim" || credential.credential_generation_id != ticket.current_credential_generation_id
              outcome = failure(error(:claim_not_current, :conflict))
              raise ActiveRecord::Rollback
            end

            claim.update!(status: "accepted", claimed_by_user: @actor, accepted_at: Time.current)
            credential.update!(holder_user: @actor)
            credential.admission_slot.update!(assigned_user: @actor, assignment_status: "claimed", claimed_at: Time.current)

            activation = activate_if_ready(ticket, credential)
            if activation.failure?
              outcome = activation
              raise ActiveRecord::Rollback
            end

            record_audit!(claim, credential)
            publish_outbox!(claim, credential)
            outcome = success(Result.new(claim: claim, credential: credential.reload))
          end
        end
        outcome
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_workflow.errors.claim_acceptance_failed"),
            code: "claim_acceptance_failed",
            status: :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def validate_claim(claim)
        return error(:claim_recipient_mismatch, :forbidden) unless recipient?(claim)
        return error(:claim_expired, :conflict) if claim.expires_at.present? && claim.expires_at <= Time.current
        return error(:claim_not_pending, :conflict) unless claim.status == "pending"
        return error(:claim_recipient_unverified, :unprocessable_entity) unless @actor.verified_at.present?

        nil
      end

      def recipient?(claim)
        @actor.is_a?(Core::User) && claim.invited_user_id == @actor.id
      end

      def load_credential(claim)
        Ticketing::Credential.includes(
          :credential_generation,
          :admission_slot,
          ticket: [
            :event,
            :owner_user,
            :current_credential_generation,
            { event_product: [ :ticket_type, { product_accesses: :event_date } ], registration: :consent_requirements }
          ]
        ).lock.find(claim.credential_id)
      end

      def activate_if_ready(ticket, credential)
        if identity_name_required?(ticket) || pending_requirement?(ticket, credential)
          credential.update!(status: "pending_requirements")
          return success(credential)
        end

        Ticketing::Credentials::Activate.call(
          credential:,
          loaded_credential: credential,
          issuance_context: {
            reserved_lookup_codes: Ticketing::Credential.where(event_id: ticket.event_id).where.not(lookup_code: nil).pluck(:lookup_code).to_set,
            next_index_version: Ticketing::AttendeeIndexEntry.where(event_id: ticket.event_id).maximum(:index_version).to_i + 1
          }
        )
      end

      def pending_requirement?(ticket, credential)
        return false unless ticket.registration_id

        ticket.registration.consent_requirements.any? do |requirement|
          requirement.required? && requirement.acceptance_scope == "admission_slot" &&
            requirement.package_unit_number == ticket.unit_number &&
            requirement.admission_position == credential.admission_slot.position &&
            (requirement.pending? || requirement.subject_user_id != credential.holder_user_id)
        end
      end

      def identity_name_required?(ticket)
        ticket.event_product.ticket_type.entry_validation_mode == "qr_and_id"
      end

      def replay(claim)
        return failure(error(:claim_recipient_mismatch, :forbidden)) unless recipient?(claim)

        credential = load_credential(claim)
        success(Result.new(claim:, credential:))
      end

      def record_audit!(claim, credential)
        Core::Audit::Record.call(
          audit_key: "ticketing-credential-claim-accepted-#{claim.id}",
          action: "ticketing.credential_claim.accepted",
          auditable_type: claim.class.name,
          auditable_id: claim.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { credential_id: credential.id, status: "accepted" },
          metadata: { ticket_id: credential.ticket_id }
        )
      end

      def publish_outbox!(claim, credential)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.credential_claim.accepted",
          aggregate: claim,
          payload: { claim_id: claim.id, credential_id: credential.id, ticket_id: credential.ticket_id },
          idempotency_key: "ticketing-credential-claim-accepted-#{claim.id}"
        )
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
