# frozen_string_literal: true

require "test_helper"

module Events
  module StaffInvitations
    class RevokeForCancellationTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
      end

      test "revokes pending invitations but preserves accepted invitation history" do
        pending, pending_token = create_invitation(phone: "+251911999401")
        accepted, accepted_token = create_invitation(phone: core_users(:support).phone)
        claim = Events::StaffInvitations::Claim.call(
          token: accepted_token,
          actor: core_users(:support),
          idempotency_key: "accepted-before-cancel",
          ip_address: "203.0.113.60"
        )
        assert_predicate claim, :success?, claim.error&.message

        result = Events::StaffInvitations::RevokeForCancellation.call(event: @event, actor: @actor)

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value
        assert_equal "revoked", pending.reload.status
        assert_nil pending.claim_token_ciphertext
        assert_equal "accepted", accepted.reload.status
        audit = Core::AuditLog.find_by!(
          auditable: pending,
          action: "events.staff_invitation.revoked_for_cancellation"
        )
        refute_includes audit.metadata.to_s, pending_token
        refute_includes audit.metadata.to_s, accepted_token
      end

      test "replays cancellation cleanup without writing duplicate transition audits" do
        pending, = create_invitation(phone: "+251911999402")
        operation = -> { Events::StaffInvitations::RevokeForCancellation.call(event: @event, actor: @actor) }

        assert_audit_idempotent(
          operation,
          action: "events.staff_invitation.revoked_for_cancellation",
          auditable_type: pending.class.name,
          auditable_id: pending.id
        )
        assert_equal 0, operation.call.value
      end

      private

      def create_invitation(phone:)
        result = Events::StaffInvitations::Create.call(
          event: @event,
          actor: @actor,
          phone:,
          role: "staff",
          idempotency_key: "cancel-invite-#{SecureRandom.hex(6)}",
          ip_address: "203.0.113.61"
        )
        assert_predicate result, :success?, result.error&.message
        [ result.value.record, result.value.token ]
      end
    end
  end
end
