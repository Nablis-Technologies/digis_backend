# frozen_string_literal: true

module Organizations
  module MembershipInvitations
    class Preview < Core::BaseService
      Result = Data.define(:organization_id, :organization_name, :role, :inviter_email, :masked_contact, :expires_at)

      def initialize(token:, actor:, ip_address:, at: Time.current)
        @token = token.to_s.strip
        @actor = actor
        @ip_address = ip_address
        @at = at.to_time.utc
      end

      def call
        return failure(invalid_claim) unless actor

        token_digest = MembershipInvitation.claim_token_digest_for(token)
        throttle = Core::InvitationThrottle.call(actor_id: actor.id, token_digest:, ip_address:)
        return failure(throttle.error) if throttle.failure?
        return failure(invalid_claim) unless token.match?(/\A[0-9a-f]{64}\z/)

        invitation = MembershipInvitation.includes(:organization, :invited_by).find_by(claim_token_digest: token_digest)
        return failure(invalid_claim) unless invitation

        contact = Core::InvitationContact.parse(phone: invitation.contact_ciphertext)
        contact_throttle = Core::InvitationThrottle.call(
          actor_id: nil,
          contact_digest: contact.rate_limit_digest,
          ip_address: nil
        )
        return failure(contact_throttle.error) if contact_throttle.failure?

        validation = validate(invitation, contact)
        return failure(validation) if validation

        success(Result.new(
          organization_id: invitation.organization_id,
          organization_name: invitation.organization.name,
          role: invitation.role,
          inviter_email: invitation.invited_by.email,
          masked_contact: invitation.masked_contact,
          expires_at: invitation.expires_at
        ))
      rescue ArgumentError
        failure(invalid_claim)
      rescue ActiveRecord::RecordNotFound
        failure(invalid_claim)
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :token, :actor, :ip_address, :at

      def validate(invitation, contact)
        return invalid_claim unless invitation.pending? && invitation.expires_at > at
        return invalid_claim if invitation.organization.archived?
        return error(:invitation_phone_unverified, :forbidden) unless actor.verified_at.present?
        return error(:invitation_contact_mismatch, :forbidden) unless contact.normalized_value ==
          Core::InvitationContact.parse(phone: actor.phone).normalized_value

        nil
      rescue ArgumentError
        error(:invitation_contact_mismatch, :forbidden)
      end

      def invalid_claim
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
