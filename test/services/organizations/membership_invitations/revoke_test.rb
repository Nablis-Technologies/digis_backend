# frozen_string_literal: true

require "test_helper"

module Organizations
  module MembershipInvitations
    class RevokeTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @organization = Organizations::Organization.create!(
          name: "Membership Revoke #{SecureRandom.hex(5)}",
          organizer_type: "individual",
          category: "conference"
        )
        @owner = core_users(:attendee)
        @outsider = core_users(:core_admin)
        @organization.memberships.create!(user: @owner, role: "owner")
      end

      test "revokes a pending invitation and clears its claim token" do
        invitation, token = create_pending

        result = revoke(invitation:, actor: @owner, key: "revoke-pending")

        assert_predicate result, :success?, result.error&.message
        assert_equal "revoked", invitation.reload.status
        assert invitation.revoked_at.present?
        assert_nil invitation.claim_token_ciphertext
        assert_equal invitation.id, result.value.record.id
        audit = Core::AuditLog.find_by!(auditable: invitation, action: "organizations.membership_invitation.revoked")
        refute_includes audit.metadata.to_s, token
        refute_includes audit.metadata.to_s, invitation.contact_ciphertext
      end

      test "replays revoke without writing another audit" do
        invitation, = create_pending
        results = []
        operation = -> { results << revoke(invitation:, actor: @owner, key: "revoke-replay") }

        assert_audit_idempotent(
          operation,
          action: "organizations.membership_invitation.revoked",
          auditable_type: invitation.class.name,
          auditable_id: invitation.id
        )
        assert_predicate results.last, :success?, results.last.error&.message
        assert results.last.value.replayed?
      end

      test "rejects revoke from an actor who cannot manage the invitation" do
        invitation, = create_pending

        result = revoke(invitation:, actor: @outsider, key: "revoke-forbidden")

        assert_equal "invitation_forbidden", result.error.code
        assert_equal "pending", invitation.reload.status
      end

      test "does not revoke an already accepted invitation" do
        invitation, = create_pending
        invitation.update!(
          status: "accepted",
          accepted_user: core_users(:support),
          accepted_at: Time.current,
          claim_token_ciphertext: nil,
          claim_idempotency_key_digest: digest("accepted-claim-key"),
          claim_request_digest: digest("accepted-claim-request")
        )

        result = revoke(invitation:, actor: @owner, key: "revoke-accepted")

        assert_equal "invitation_not_revocable", result.error.code
        assert_equal "accepted", invitation.reload.status
      end

      private

      def create_pending
        phone = "+2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        result = Organizations::MembershipInvitations::Create.call(
          organization: @organization,
          actor: @owner,
          phone:,
          role: "staff",
          idempotency_key: "revoke-create-#{SecureRandom.hex(6)}",
          ip_address: "203.0.113.20"
        )
        assert_predicate result, :success?, result.error&.message
        [ result.value.record, result.value.token ]
      end

      def revoke(invitation:, actor:, key:)
        Organizations::MembershipInvitations::Revoke.call(
          invitation:,
          actor:,
          idempotency_key: key,
          ip_address: "203.0.113.21"
        )
      end

      def digest(value)
        Core::KeyedDigest.digest(namespace: "test/membership-invitation-revoke", value:)
      end
    end
  end
end
