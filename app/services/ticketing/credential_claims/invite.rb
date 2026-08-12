# frozen_string_literal: true

require "securerandom"

module Ticketing
  class CredentialClaims
    # Creates a one-time claim for an unassigned delegated slot. The raw token
    # is returned exactly once and is never written to the database, audit log,
    # or outbox payload.
    class Invite < Core::BaseService
      Result = Data.define(:claim, :token)

      def initialize(credential:, actor:, phone:, idempotency_key:, expires_at: nil)
        @credential = credential
        @actor = actor
        @phone = phone
        @idempotency_key = idempotency_key
        @expires_at = expires_at
      end

      def call
        key = Core::IdempotencyKey.new(@idempotency_key)
        requested_expiry = parse_expiry
        return failure(error(:claim_expiry_invalid, :unprocessable_entity)) if @expires_at.present? && requested_expiry.nil?

        outcome = nil
        Ticketing::Credential.transaction do
          credential = load_credential
          validation = validate(credential)
          if validation
            outcome = failure(validation)
            raise ActiveRecord::Rollback
          end

          identity = Core::PhoneIdentity::ResolveOrCreate.call(
            phone: @phone,
            actor: @actor,
            allow_actor_mismatch: true
          )
          if identity.failure?
            outcome = identity
            raise ActiveRecord::Rollback
          end

          token = SecureRandom.urlsafe_base64(32)
          claim = Ticketing::CredentialClaim.create!(
            credential:,
            invited_user: identity.value.user,
            contact_digest: Ticketing::CredentialClaim.contact_digest_for(phone: identity.value.user.phone),
            token_digest: Ticketing::CredentialClaim.token_digest_for(token:),
            status: "pending",
            expires_at: expiry(credential, requested_expiry)
          )
          record_audit!(claim, credential, key)
          publish_outbox!(claim, credential, key)
          outcome = success(Result.new(claim:, token:))
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(error(:credential_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid
        failure(error(:claim_conflict, :conflict))
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :unprocessable_entity))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def load_credential
        Ticketing::Credential.includes(
          :credential_generation,
          :credential_claim,
          :admission_slot,
          ticket: [ :owner_user, { event_product: [ :ticket_type, { product_accesses: :event_date } ] } ]
        ).lock.find(@credential.id)
      end

      def validate(credential)
        ticket = credential.ticket
        return error(:claim_forbidden, :forbidden) unless @actor.is_a?(Core::User) && ticket.owner_user_id == @actor.id
        return error(:claim_not_pending, :conflict) unless credential.status == "pending_claim"
        return error(:delegation_not_active, :conflict) unless credential.credential_generation.mode == "delegated"
        return error(:claim_already_exists, :conflict) if credential.credential_claim.present?
        return error(:generation_cutoff_passed, :conflict) if cutoff_passed?(ticket)

        nil
      end

      def expiry(credential, requested_expiry)
        requested = requested_expiry || 7.days.from_now
        cutoff = cutoff_at(credential.ticket)
        [ requested, cutoff ].compact.min
      end

      def parse_expiry
        return @expires_at if @expires_at.is_a?(Time)
        return if @expires_at.blank?

        Time.zone.parse(@expires_at.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def cutoff_at(ticket)
        dates = ticket.event_product.product_accesses.map(&:event_date).compact.reject { |date| date.status == "cancelled" }
        return if dates.empty?

        seconds = ticket.event_product.ticket_type.transfer_cutoff_seconds_before_start.to_i
        dates.map { |date| date.starts_at - seconds.seconds }.min
      end

      def cutoff_passed?(ticket)
        cutoff = cutoff_at(ticket)
        cutoff.present? && Time.current >= cutoff
      end

      def record_audit!(claim, credential, key)
        Core::Audit::Record.call(
          audit_key: "ticketing-credential-claim-invite-#{key.digest}",
          action: "ticketing.credential_claim.invited",
          auditable_type: claim.class.name,
          auditable_id: claim.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { credential_id: credential.id, invited_user_id: claim.invited_user_id },
          metadata: { ticket_id: credential.ticket_id, idempotency_key_digest: key.digest }
        )
      end

      def publish_outbox!(claim, credential, key)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.credential_claim.invited",
          aggregate: claim,
          payload: { claim_id: claim.id, credential_id: credential.id, ticket_id: credential.ticket_id },
          idempotency_key: "ticketing-credential-claim-invite-#{key.digest}"
        )
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
