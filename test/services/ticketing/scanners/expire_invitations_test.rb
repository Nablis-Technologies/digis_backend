# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class ExpireInvitationsTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @now = Time.current
        @pending = create_expired_invitation(phone: "0911 23 45 81")
        @reset = create_expired_invitation(phone: "0911 23 45 82")
        @reset.update!(status: "pairing_reset")
        @current = create_current_invitation(phone: "0911 23 45 83")
      end

      test "expires pending and reset invitations, clears secrets, and publishes safe lifecycle evidence" do
        result = ExpireInvitations.call(at: @now)

        assert result.success?, result.error&.message
        assert_equal 2, result.value
        Prosopite.pause do
          [ @pending, @reset ].each do |invitation|
            invitation.reload
            assert_equal "expired", invitation.status
            assert invitation.expired_at.present?
            assert_nil invitation.token
            assert_nil invitation.pairing_code
            assert Core::AuditLog.exists?(
              auditable: invitation, action: "ticketing.scanner_invitation.expired"
            )
            outbox = Core::OutboxEvent.find_by!(
              event_type: "ticketing.scanner_invitation.expired",
              aggregate_id: invitation.id
            )
            assert_equal({ "invitation_id" => invitation.id }, outbox.payload)
          end
        end
        assert_equal "pending", @current.reload.status
      end

      test "replays expiry without duplicate audit or outbox records" do
        first = ExpireInvitations.call(at: @now)
        second = ExpireInvitations.call(at: @now)

        assert first.success?
        assert second.success?
        assert_equal 2, first.value
        assert_equal 0, second.value
        assert_equal 1, Core::AuditLog.where(
          auditable: @pending, action: "ticketing.scanner_invitation.expired"
        ).count
        assert_equal 1, Core::OutboxEvent.where(
          event_type: "ticketing.scanner_invitation.expired", aggregate_id: @pending.id
        ).count
      end

      private

      def create_expired_invitation(phone:)
        created = CreateInvitation.call(
          event: @event,
          actor: @actor,
          phone:,
          starts_at: 3.hours.ago,
          ends_at: 3.days.from_now,
          expires_at: 1.hour.ago,
          idempotency_key: "expire-invite-#{SecureRandom.hex(5)}",
          at: 2.hours.ago
        )
        raise created.error unless created.success?

        created.value.record
      end

      def create_current_invitation(phone:)
        created = CreateInvitation.call(
          event: @event,
          actor: @actor,
          phone:,
          starts_at: 1.minute.ago,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: "current-invite-#{SecureRandom.hex(5)}",
          at: @now
        )
        raise created.error unless created.success?

        created.value.record
      end
    end
  end
end
