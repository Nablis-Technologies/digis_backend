# frozen_string_literal: true

require "test_helper"

module Events
  module StaffAssignments
    class AssignFromDelegatedGrantTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @organization = @event.organization
        @grantor = Core::User.create!(
          email: "grantor-#{SecureRandom.hex(5)}@example.com",
          phone: "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        )
        @operator = Core::User.create!(
          email: "operator-#{SecureRandom.hex(5)}@example.com",
          phone: "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        )
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @grantor,
          organization: @organization,
          role: "manager",
          status: "active"
        )
      end

      test "defines the Events-owned delegated assignment command" do
        assert StaffAssignments.const_defined?(:AssignFromDelegatedGrant, false)
      end

      test "creates the scanner assignment from an issued grant after the grantor role is removed" do
        grant = delegated_grant
        @event.event_staff_assignments.find_by!(user: @grantor, role: "manager").update!(status: "revoked")

        result = AssignFromDelegatedGrant.call(
          event: @event,
          organization: @organization,
          user: @operator,
          grant:
        )

        assert result.success?
        assignment = result.value
        assert_equal "scanner", assignment.role
        assert_equal "active", assignment.status
        assert_equal @operator.id, assignment.user_id
        audit = Core::AuditLog.find_by!(auditable: assignment, action: "event.staff.assigned_from_grant")
        assert_equal @grantor.id, audit.actor_id
        assert_equal grant.source_id, audit.metadata.fetch("grant_source_id")
      end

      test "rejects a grant for another event or role" do
        other_event_grant = delegated_grant(event: events_events(:draft_concert))
        wrong_role_grant = delegated_grant(role: "manager")

        [ other_event_grant, wrong_role_grant ].each do |grant|
          result = AssignFromDelegatedGrant.call(
            event: @event,
            organization: @organization,
            user: @operator,
            grant:
          )
          refute result.success?
          assert_equal "delegated_grant_invalid", result.error.code
        end
      end

      private

      def delegated_grant(event: @event, role: "scanner")
        DelegatedGrant.new(
          event_id: event.id,
          role:,
          grantor_id: @grantor.id,
          source_type: "Ticketing::ScannerInvitation",
          source_id: SecureRandom.uuid,
          issued_at: Time.current
        )
      end
    end
  end
end
