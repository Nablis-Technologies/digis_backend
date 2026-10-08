# frozen_string_literal: true

require "test_helper"

module Ticketing
  module OutboxHandlers
    class RevokeScannerAssignmentTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 1)
        @pairing = pair_scanner(event: @event, actor: @manager, operator: @other_user)
        @session = @pairing.session
        @assignment = @session.scanner_device_assignment
        published = Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.staff_assignment.revoked",
          aggregate: @assignment.event_staff_assignment,
          payload: {
            event_staff_assignment_id: @assignment.event_staff_assignment_id,
            actor_id: @manager.id
          },
          idempotency_key: "test-event-staff-revoked-#{@assignment.event_staff_assignment_id}"
        )
        raise published.error unless published.success?

        @outbox_event = published.value
      end

      test "revokes bound device assignment and session after the Events-owned role revocation" do
        result = RevokeScannerAssignment.call(event: @outbox_event)

        assert result.success?, result.error&.message
        assert_equal "revoked", @assignment.reload.status
        assert @session.reload.revoked_at.present?
      end

      test "cleanup is idempotent and does not create duplicate audits" do
        first = RevokeScannerAssignment.call(event: @outbox_event)
        second = RevokeScannerAssignment.call(event: @outbox_event)

        assert first.success?, first.error&.message
        assert second.success?, second.error&.message
        assert_equal 1, Core::AuditLog.where(
          auditable: @assignment,
          action: "ticketing.scanner_device_assignment.revoked"
        ).count
      end

      test "Events revoke denies the next scanner request before Ticketing outbox cleanup runs" do
        revoked = Events::StaffAssignments::Revoke.call(
          assignment: @assignment.event_staff_assignment,
          actor: @manager,
          idempotency_key: "event-role-revoke-#{@assignment.event_staff_assignment_id}"
        )
        assert revoked.success?, revoked.error&.message

        denied = Scanners::AuthenticateSession.call(
          token: @pairing.scanner_session_token,
          event: @event
        )
        assert_equal "operator_forbidden", denied.error.code
        assert_equal "active", @assignment.reload.status

        outbox = Core::OutboxEvent.find_by!(
          event_type: "events.staff_assignment.revoked",
          aggregate_id: @assignment.event_staff_assignment_id
        )
        cleanup = Core::Outbox::Dispatch.call(event_id: outbox.id)

        assert cleanup.success?, cleanup.error&.message
        assert_predicate outbox.reload, :published_at?
        assert_equal "revoked", @assignment.reload.status
        assert @session.reload.revoked_at.present?
        assert_equal "revoked", @pairing.invitation.reload.status
      end
    end
  end
end
