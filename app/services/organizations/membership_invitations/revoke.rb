# frozen_string_literal: true

module Organizations
  module MembershipInvitations
    class Revoke < Core::BaseService
      Result = Data.define(:record, :replayed) do
        def replayed? = replayed
      end

      def initialize(invitation:, actor:, idempotency_key:, ip_address:, at: Time.current)
        @invitation = invitation
        @actor = actor
        @idempotency_key_input = idempotency_key
        @ip_address = ip_address
        @at = at.to_time.utc
      end

      def call
        key = idempotency_key
        return failure(error(:invalid_idempotency_key, :bad_request)) unless key
        return failure(error(:invitation_forbidden, :forbidden)) unless authorized?

        command_key = command_key_digest(key)
        request_digest = request_digest_for
        outcome = nil

        MembershipInvitation.transaction do
          invitation.lock!
          replay = replay_command(command_key:, request_digest:)
          if replay
            outcome = replay
            next
          end

          unless invitation.pending? && invitation.expires_at > at
            expire_if_due!
            outcome = failure(error(:invitation_not_revocable, :conflict))
            next
          end

          contact = invitation_contact
          throttle = Core::InvitationThrottle.call(
            actor_id: actor.id,
            contact_digest: contact.rate_limit_digest,
            ip_address:
          )
          unless throttle.success?
            outcome = failure(throttle.error)
            next
          end

          invitation.update!(status: "revoked", revoked_at: at, claim_token_ciphertext: nil)
          invitation.record_audit!(
            "organizations.membership_invitation.revoked",
            actor:,
            audit_key: command_key,
            audited_changes: { status: [ "pending", "revoked" ] },
            metadata: { invitation_id: invitation.id, organization_id: invitation.organization_id, request_digest: }
          )
          outcome = success(Result.new(record: invitation, replayed: false))
        end
        outcome
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("organizations.membership_invitation.errors.invalid"),
          code: "membership_invitation_invalid",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :invitation, :actor, :idempotency_key_input, :ip_address, :at

      def idempotency_key
        Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def authorized?
        actor && Organizations::MembershipPolicy.new(actor, invitation).destroy?
      end

      def invitation_contact
        attributes = if invitation.contact_type == "phone"
          { phone: invitation.contact_ciphertext }
        else
          { email: invitation.contact_ciphertext }
        end
        Core::InvitationContact.parse(**attributes)
      end

      def command_key_digest(key)
        Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-revoke/#{invitation.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def request_digest_for
        Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-revoke-request",
          value: ActiveSupport::JSON.encode(invitation_id: invitation.id, actor_id: actor.id)
        )
      end

      def replay_command(command_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key: command_key)
        return unless audit

        return failure(error(:idempotency_conflict, :conflict)) unless audit.metadata.deep_stringify_keys[
          "request_digest"
        ] == request_digest

        success(Result.new(record: invitation, replayed: true))
      end

      def expire_if_due!
        return unless invitation.pending? && invitation.expires_at <= at

        result = Expire.call(
          organization_id: invitation.organization_id,
          contact_digest: invitation.contact_digest,
          at:,
          limit: 1
        )
        raise result.error if result.failure?
      end

      def error(key, status)
        Core::BusinessError.new(
          I18n.t("organizations.membership_invitation.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
