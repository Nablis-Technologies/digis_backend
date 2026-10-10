# frozen_string_literal: true

module Organizations
  module MembershipInvitations
    class Claim < Core::BaseService
      Result = Data.define(:record, :membership, :replayed, :already_member) do
        def replayed? = replayed
        def already_member? = already_member
      end

      def initialize(token:, actor:, idempotency_key:, ip_address:, at: Time.current)
        @token = token.to_s.strip
        @actor = actor
        @idempotency_key_input = idempotency_key
        @ip_address = ip_address
        @at = at.to_time.utc
      end

      def call
        return failure(error(:invalid_idempotency_key, :bad_request)) unless idempotency_key
        return failure(claim_invalid) unless actor

        token_digest = MembershipInvitation.claim_token_digest_for(token)
        request_digest = claim_request_digest(token_digest)
        audit_key = claim_audit_key
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        preflight = Core::InvitationThrottle.call(actor_id: actor.id, token_digest:, ip_address:)
        return failure(preflight.error) if preflight.failure?
        return failure(claim_invalid) unless token.match?(/\A[0-9a-f]{64}\z/)

        invitation = MembershipInvitation.find_by(claim_token_digest: token_digest)
        return failure(claim_invalid) unless invitation

        contact = invitation_contact(invitation)
        return failure(claim_invalid) unless contact
        contact_throttle = Core::InvitationThrottle.call(
          actor_id: nil,
          contact_digest: contact.rate_limit_digest,
          ip_address: nil
        )
        return failure(contact_throttle.error) if contact_throttle.failure?

        result = nil
        MembershipInvitation.transaction do
          invitation.lock!
          replay = replay_result(audit_key:, request_digest:)
          if replay
            result = replay
            next
          end

          validation = validate_claim(invitation, contact)
          if validation
            expire_if_due!(invitation)
            result = failure(validation)
            next
          end

          membership = current_membership(invitation)
          already_member = membership.present?
          if membership&.suspended?
            result = failure(error(:membership_not_active, :conflict))
            next
          end
          if membership && membership.role != invitation.role
            result = failure(error(:membership_role_change_required, :conflict))
            next
          end

          membership ||= invitation.organization.memberships.create!(user: actor, role: invitation.role, status: "active")
          invitation.update!(
            status: "accepted",
            accepted_user: actor,
            accepted_at: at,
            claim_token_ciphertext: nil,
            claim_idempotency_key_digest: audit_key,
            claim_request_digest: request_digest
          )
          invitation.record_audit!(
            "organizations.membership_invitation.accepted",
            actor:,
            audit_key:,
            audited_changes: { status: [ "pending", "accepted" ] },
            metadata: {
              invitation_id: invitation.id,
              organization_id: invitation.organization_id,
              accepted_user_id: actor.id,
              membership_id: membership.id,
              role: invitation.role,
              request_digest:,
              already_member:
            }
          )
          result = success(Result.new(record: invitation, membership:, replayed: false, already_member:))
        end
        result
      rescue ActiveRecord::RecordNotFound
        failure(claim_invalid)
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

      attr_reader :token, :actor, :idempotency_key_input, :ip_address, :at

      def idempotency_key
        @idempotency_key ||= Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def claim_audit_key
        Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-claim/#{actor.id}",
          value: idempotency_key.to_s
        )
      end

      def claim_request_digest(token_digest)
        Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-claim-request/#{actor.id}",
          value: token_digest
        )
      end

      def replay_result(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        metadata = audit.metadata.deep_stringify_keys
        return failure(error(:idempotency_conflict, :conflict)) unless metadata["request_digest"] == request_digest

        invitation = MembershipInvitation.find_by(id: metadata["invitation_id"])
        membership = Organizations::Membership.find_by(id: metadata["membership_id"])
        return failure(claim_invalid) unless invitation && membership

        success(Result.new(
          record: invitation,
          membership:,
          replayed: true,
          already_member: metadata["already_member"] == true || metadata["already_member"] == "true"
        ))
      end

      def validate_claim(invitation, contact)
        return claim_invalid unless invitation.pending? && invitation.expires_at > at
        return claim_invalid if invitation.organization.archived?
        return error(:invitation_phone_unverified, :forbidden) unless actor.verified_at.present?
        return error(:invitation_contact_mismatch, :forbidden) unless contact.normalized_value ==
          Core::InvitationContact.parse(phone: actor.phone).normalized_value

        nil
      rescue ArgumentError
        error(:invitation_contact_mismatch, :forbidden)
      end

      def invitation_contact(invitation)
        return unless invitation.contact_type == "phone"

        Core::InvitationContact.parse(phone: invitation.contact_ciphertext)
      rescue ArgumentError, ActiveRecord::Encryption::Errors::Decryption
        nil
      end

      def current_membership(invitation)
        invitation.organization.memberships.lock.find_by(user_id: actor.id)
      end

      def expire_if_due!(invitation)
        return unless invitation.pending? && invitation.expires_at <= at

        result = Expire.call(
          organization_id: invitation.organization_id,
          contact_digest: invitation.contact_digest,
          at:,
          limit: 1
        )
        raise result.error if result.failure?
      end

      def claim_invalid
        error(:membership_invitation_claim_invalid, :unauthorized)
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
