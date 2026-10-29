# frozen_string_literal: true

require "test_helper"

module Organizations
  module MembershipInvitations
    class ClaimTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @organization = Organizations::Organization.create!(
          name: "Membership Claim #{SecureRandom.hex(5)}",
          organizer_type: "individual",
          category: "conference"
        )
        @owner = core_users(:attendee)
        @invitee = core_users(:support)
        @organization.memberships.create!(user: @owner, role: "owner")
      end

      test "accepts a matching verified phone claim and creates only the scoped membership" do
        invitation, token = create_invitation
        existing_global_roles = @invitee.roles.pluck(:id)

        result = claim(invitation:, token:, key: "accept-once")

        assert_predicate result, :success?, result.error&.message
        assert_equal @organization.id, result.value.membership.organization_id
        assert_equal @invitee.id, result.value.membership.user_id
        assert_equal "staff", result.value.membership.role
        assert_equal "active", result.value.membership.status
        assert_equal "accepted", invitation.reload.status
        assert_nil invitation.claim_token_ciphertext
        assert_equal existing_global_roles, @invitee.roles.pluck(:id)
        assert Core::AuditLog.exists?(
          auditable: invitation,
          action: "organizations.membership_invitation.accepted"
        )
      end

      test "replays an accepted claim idempotently without duplicating membership or audit" do
        invitation, token = create_invitation
        results = []
        operation = -> { results << claim(invitation:, token:, key: "claim-replay") }
        counter = -> {
          @organization.memberships.count +
            Core::AuditLog.where(auditable: invitation, action: "organizations.membership_invitation.accepted").count
        }

        assert_idempotent(operation, counter:)
        first, replay = results
        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert replay.value.replayed?
        assert_equal first.value.membership.id, replay.value.membership.id
      end

      test "rejects a claimant whose verified phone differs from the invitation" do
        invitation, token = create_invitation

        result = claim(invitation:, token:, key: "wrong-phone", actor: @owner)

        assert_equal "invitation_contact_mismatch", result.error.code
        assert_equal "pending", invitation.reload.status
        assert_empty @organization.memberships.where.not(user_id: @owner.id)
      end

      test "rejects an unverified claimant without consuming the invitation" do
        invitation, token = create_invitation
        @invitee.update!(verified_at: nil)

        result = claim(invitation:, token:, key: "unverified")

        assert_equal "invitation_phone_unverified", result.error.code
        assert_equal "pending", invitation.reload.status
        assert_empty @organization.memberships.where(user_id: @invitee.id)
      end

      test "fails closed when persisted invitation contact ciphertext cannot be decrypted" do
        invitation, token = create_invitation
        connection = ActiveRecord::Base.connection
        connection.execute(
          "UPDATE organizations_membership_invitations " \
          "SET contact_ciphertext = #{connection.quote("not-encrypted")} " \
          "WHERE id = #{connection.quote(invitation.id)}"
        )

        result = claim(invitation:, token:, key: "corrupt-contact-ciphertext")

        assert_equal "membership_invitation_claim_invalid", result.error.code
        assert_empty @organization.memberships.where(user_id: @invitee.id)
      end

      test "fails closed when encrypted invitation phone decrypts to an invalid phone" do
        invitation, token = create_invitation
        invitation.update_columns(contact_ciphertext: "+123")

        result = claim(invitation:, token:, key: "malformed-stored-invitation-phone")

        assert_equal "membership_invitation_claim_invalid", result.error.code
        assert_empty @organization.memberships.where(user_id: @invitee.id)
      end

      test "rejects an expired or revoked claim without creating membership" do
        expired_expires_at = 1.minute.from_now
        expired, expired_token = create_invitation(expires_at: expired_expires_at)
        revoked, revoked_token = create_invitation(phone: "+251911999099")
        revoked.update!(status: "revoked", revoked_at: Time.current, claim_token_ciphertext: nil)

        expired_result = nil
        travel_to(expired_expires_at + 1.second) do
          expired.update!(status: "expired", expired_at: Time.current, claim_token_ciphertext: nil)
          expired_result = claim(invitation: expired, token: expired_token, key: "expired", at: Time.current)
        end
        revoked_result = claim(invitation: revoked, token: revoked_token, key: "revoked")

        assert_equal "membership_invitation_claim_invalid", expired_result.error.code
        assert_equal "membership_invitation_claim_invalid", revoked_result.error.code
        assert_empty @organization.memberships.where(user_id: @invitee.id)
      end

      test "returns an idempotency conflict when a claim key is reused for a different capability" do
        invitation, token = create_invitation
        first = claim(invitation:, token:, key: "claim-key-conflict")
        second = claim(invitation:, token: "f" * 64, key: "claim-key-conflict")

        assert_predicate first, :success?, first.error&.message
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 1, @organization.memberships.where(user_id: @invitee.id).count
      end

      test "requires the existing membership role to be changed through the authorized role command" do
        existing = @organization.memberships.create!(user: @invitee, role: "admin", status: "active")
        invitation, token = create_invitation(role: "staff")

        result = claim(invitation:, token:, key: "already-member")

        assert_equal "membership_role_change_required", result.error.code
        assert_equal "admin", existing.reload.role
        assert_equal 1, @organization.memberships.where(user_id: @invitee.id).count
        assert_equal "pending", invitation.reload.status
      end

      test "accepts an invitation for a user already holding the same active role" do
        existing = @organization.memberships.create!(user: @invitee, role: "staff", status: "active")
        invitation, token = create_invitation(role: "staff")

        result = claim(invitation:, token:, key: "same-role-member")

        assert_predicate result, :success?, result.error&.message
        assert_equal existing.id, result.value.membership.id
        assert result.value.already_member?
        assert_equal "staff", existing.reload.role
        assert_equal 1, @organization.memberships.where(user_id: @invitee.id).count
        assert_equal "accepted", invitation.reload.status
      end

      private

      def create_invitation(phone: @invitee.phone, role: "staff", expires_at: 7.days.from_now)
        token = SecureRandom.hex(32)
        contact = Core::InvitationContact.parse(phone:)
        invitation = Organizations::MembershipInvitation.create!(
          organization: @organization,
          invited_by: @owner,
          role:,
          contact_type: "phone",
          contact_ciphertext: contact.normalized_value,
          contact_digest: contact.digest_for(
            scope_type: Organizations::MembershipInvitation::CONTACT_DIGEST_SCOPE,
            scope_id: @organization.id
          ),
          status: "pending",
          claim_token_ciphertext: token,
          claim_token_digest: Core::KeyedDigest.digest(
            namespace: "organizations/membership-invitation-token", value: token
          ),
          delivery_status: "queued",
          delivery_revision: 1,
          delivery_attempts: 0,
          expires_at:,
          create_idempotency_key_digest: digest(SecureRandom.hex(16)),
          create_request_digest: digest(SecureRandom.hex(16))
        )
        [ invitation, token ]
      end

      def claim(invitation:, token:, key:, actor: @invitee, at: Time.current)
        Organizations::MembershipInvitations::Claim.call(
          token:,
          actor:,
          idempotency_key: key,
          ip_address: "203.0.113.10",
          at:
        )
      end

      def digest(value)
        Core::KeyedDigest.digest(namespace: "test/membership-invitation-claim", value:)
      end
    end
  end
end
