# frozen_string_literal: true

require "test_helper"

module Events
  module StaffInvitations
    class ResendTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @event = events_events(:ready_listing)
        @owner = core_users(:core_admin)
        @outsider = core_users(:attendee)
      end

      test "rotates the token without extending invitation expiry and publishes the new revision" do
        invitation, old_token = create_pending
        original_digest = invitation.claim_token_digest
        original_expiry = invitation.expires_at
        original_delivery_count = delivery_count(invitation)

        result = resend(invitation:, actor: @owner, key: "event-resend-rotate")

        assert_predicate result, :success?, result.error&.message
        assert_equal original_expiry, invitation.reload.expires_at
        assert_equal 2, invitation.delivery_revision
        assert_not_equal original_digest, invitation.claim_token_digest
        assert_not_equal old_token, result.value.token
        assert_equal original_delivery_count + 1, delivery_count(invitation)
        audit = Core::AuditLog.find_by!(auditable: invitation, action: "events.staff_invitation.resent")
        refute_includes audit.metadata.to_s, old_token
        refute_includes audit.metadata.to_s, result.value.token
      end

      test "replays the same resend without rotating or publishing another delivery" do
        invitation, = create_pending
        results = []
        operation = -> { results << resend(invitation:, actor: @owner, key: "event-resend-replay") }
        counter = -> { invitation.reload.delivery_revision + delivery_count(invitation) }

        assert_idempotent(operation, counter:)

        assert_predicate results.last, :success?, results.last.error&.message
        assert results.last.value.replayed?
        assert_equal results.first.value.token, results.last.value.token
      end

      test "rejects resend when the actor cannot manage the invite or the event is cancelled" do
        invitation, = create_pending
        forbidden = resend(invitation:, actor: @outsider, key: "event-resend-forbidden")
        assert_equal "invitation_forbidden", forbidden.error.code

        @event.update!(status: "cancelled")
        cancelled = resend(invitation:, actor: @owner, key: "event-resend-cancelled")

        assert_equal "event_not_invitable", cancelled.error.code
        assert_equal 1, invitation.reload.delivery_revision
      end

      test "expires a due invitation and refuses to resend it" do
        invitation, = create_pending(expires_at: 1.minute.from_now)

        result = resend(invitation:, actor: @owner, key: "event-resend-expired", at: invitation.expires_at + 1.second)

        assert_equal "invitation_not_resendable", result.error.code
        assert_equal "expired", invitation.reload.status
        assert_nil invitation.claim_token_ciphertext
        assert_equal 1, invitation.delivery_revision
      end

      private

      def create_pending(expires_at: 7.days.from_now)
        result = Events::StaffInvitations::Create.call(
          event: @event,
          actor: @owner,
          phone: "+2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}",
          role: "staff",
          idempotency_key: "event-resend-create-#{SecureRandom.hex(6)}",
          ip_address: "203.0.113.51",
          at: expires_at - 7.days
        )
        assert_predicate result, :success?, result.error&.message
        [ result.value.record, result.value.token ]
      end

      def resend(invitation:, actor:, key:, at: Time.current)
        Events::StaffInvitations::Resend.call(
          invitation:,
          actor:,
          idempotency_key: key,
          ip_address: "203.0.113.52",
          at:
        )
      end

      def delivery_count(invitation)
        Core::OutboxEvent.where(
          event_type: "events.staff_invitation.delivery_requested",
          aggregate_id: invitation.id
        ).count
      end
    end
  end
end
