# frozen_string_literal: true

require "test_helper"

module Ticketing
  module OutboxHandlers
    class CancelEventScannerAccessTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 1)
        @paired = pair_scanner(event: @event, actor: @manager, operator: @other_user)
        @session = @paired.session
        @assignment = @session.scanner_device_assignment
        pending = Scanners::CreateInvitation.call(
          event: @event,
          actor: @manager,
          phone: "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}",
          starts_at: 1.minute.ago,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: "pending-cancel-invite-#{SecureRandom.hex(6)}"
        )
        raise pending.error unless pending.success?

        @pending_invitation = pending.value.record
      end

      test "cancellation outbox revokes active scanner sessions and pending pairing material" do
        cancellation = Events::Cancellation::Initiate.call(
          event: @event,
          actor: @manager,
          attendee_reason: "Cancellation lifecycle regression test",
          idempotency_key: "scanner-event-cancel-#{SecureRandom.hex(6)}"
        )
        assert cancellation.success?, cancellation.error&.message
        @outbox_event = Core::OutboxEvent.find_by!(
          event_type: "events.cancellation_initiated",
          aggregate_id: @event.id
        )

        denied = Scanners::AuthenticateSession.call(
          token: @paired.scanner_session_token,
          event: @event
        )
        assert_equal "event_not_available", denied.error.code

        result = CancelEventScannerAccess.call(event: @outbox_event)

        assert result.success?, result.error&.message
        assert_equal "revoked", @paired.invitation.reload.status
        assert_equal "revoked", @pending_invitation.reload.status
        assert_nil @pending_invitation.token
        assert_nil @pending_invitation.pairing_code
        assert @session.reload.revoked_at.present?
        assert_equal "revoked", @assignment.reload.status
      end

      test "event cancellation cleanup can be replayed without duplicate transition audits" do
        cancellation = Events::Cancellation::Initiate.call(
          event: @event,
          actor: @manager,
          attendee_reason: "Cancellation lifecycle regression test",
          idempotency_key: "scanner-event-cancel-replay-#{SecureRandom.hex(6)}"
        )
        assert cancellation.success?, cancellation.error&.message
        outbox = Core::OutboxEvent.find_by!(
          event_type: "events.cancellation_initiated",
          aggregate_id: @event.id
        )

        first = Core::Outbox::Dispatch.call(event_id: outbox.id)
        second = Core::Outbox::Dispatch.call(event_id: outbox.id)

        assert first.success?, first.error&.message
        assert second.success?, second.error&.message
        assert_predicate outbox.reload, :published_at?
        assert_equal 1, Core::AuditLog.where(
          auditable: @paired.invitation,
          action: "ticketing.scanner_invitation.event_cancelled"
        ).count
      end
    end
  end
end
