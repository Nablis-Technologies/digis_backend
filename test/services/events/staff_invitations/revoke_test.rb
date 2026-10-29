# frozen_string_literal: true

require "test_helper"

module Events
  module StaffInvitations
    class RevokeTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @event = events_events(:ready_listing)
        @owner = core_users(:core_admin)
        @outsider = core_users(:attendee)
      end

      test "revokes a pending invitation and clears its capability" do
        invitation, token = create_pending

        result = revoke(invitation:, actor: @owner, key: "event-revoke")

        assert_predicate result, :success?, result.error&.message
        assert_equal "revoked", invitation.reload.status
        assert invitation.revoked_at.present?
        assert_nil invitation.claim_token_ciphertext
        assert_equal invitation.id, result.value.record.id
        audit = Core::AuditLog.find_by!(auditable: invitation, action: "events.staff_invitation.revoked")
        refute_includes audit.metadata.to_s, token
        refute_includes audit.metadata.to_s, invitation.contact_ciphertext
      end

      test "replays revoke without creating a second audit" do
        invitation, = create_pending
        operation = -> { revoke(invitation:, actor: @owner, key: "event-revoke-replay") }

        assert_audit_idempotent(
          operation,
          action: "events.staff_invitation.revoked",
          auditable_type: invitation.class.name,
          auditable_id: invitation.id
        )
        result = operation.call
        assert_predicate result, :success?, result.error&.message
        assert result.value.replayed?
      end

      test "rejects revoke when the actor cannot manage the invitation" do
        invitation, = create_pending

        result = revoke(invitation:, actor: @outsider, key: "event-revoke-forbidden")

        assert_equal "invitation_forbidden", result.error.code
        assert_equal "pending", invitation.reload.status
      end

      test "does not revoke an accepted invitation" do
        invitation, token = create_pending
        accepted = Events::StaffInvitations::Claim.call(
          token:,
          actor: core_users(:support),
          idempotency_key: "event-accepted-before-revoke",
          ip_address: "203.0.113.53"
        )
        assert_predicate accepted, :success?, accepted.error&.message

        result = revoke(invitation:, actor: @owner, key: "event-revoke-accepted")

        assert_equal "invitation_not_revocable", result.error.code
        assert_equal "accepted", invitation.reload.status
      end

      private

      def create_pending
        result = Events::StaffInvitations::Create.call(
          event: @event,
          actor: @owner,
          phone: core_users(:support).phone,
          role: "staff",
          idempotency_key: "event-revoke-create-#{SecureRandom.hex(6)}",
          ip_address: "203.0.113.54"
        )
        assert_predicate result, :success?, result.error&.message
        [ result.value.record, result.value.token ]
      end

      def revoke(invitation:, actor:, key:)
        Events::StaffInvitations::Revoke.call(
          invitation:,
          actor:,
          idempotency_key: key,
          ip_address: "203.0.113.55"
        )
      end
    end
  end
end
