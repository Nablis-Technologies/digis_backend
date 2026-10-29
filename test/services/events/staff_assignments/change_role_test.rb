# frozen_string_literal: true

require "test_helper"

module Events
  module StaffAssignments
    class ChangeRoleTest < ActiveSupport::TestCase
      def setup
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
        @user = core_users(:attendee)
        @organization = organizations_organizations(:two)
        @assignment = Events::EventStaffAssignment.create!(
          event: @event,
          user: @user,
          organization: @organization,
          role: "staff",
          status: "active"
        )
      end

      test "changes role and audits event.staff.role_changed" do
        result = Events::StaffAssignments::ChangeRole.call(
          assignment: @assignment,
          actor: @actor,
          role: "scanner"
        )

        assert result.success?
        @assignment.reload
        assert_equal "scanner", @assignment.role

        audit = Core::AuditLog.where(auditable: @assignment, action: "event.staff.role_changed").last
        assert audit, "expected an audit log entry for the role change"
        assert_equal({ "old" => "staff", "new" => "scanner" }, audit.audited_changes["role"])
      end

      test "invalid role returns failure with code invalid_role" do
        result = Events::StaffAssignments::ChangeRole.call(
          assignment: @assignment,
          actor: @actor,
          role: "wizard"
        )

        refute result.success?
        assert_equal "invalid_role", result.error.code
      end

      test "cannot promote scanner while the user holds another active general role" do
        scanner_assignment = Events::EventStaffAssignment.create!(
          event: @event,
          user: @user,
          organization: @organization,
          role: "scanner",
          status: "active"
        )

        result = Events::StaffAssignments::ChangeRole.call(
          assignment: scanner_assignment,
          actor: @actor,
          role: "manager"
        )

        refute_predicate result, :success?
        assert_equal "staff_assignment_role_change_required", result.error.code
        assert_equal "scanner", scanner_assignment.reload.role
        assert_equal [ "staff" ], @event.event_staff_assignments.where(
          event_id: @event.id, user_id: @user.id, status: "active"
        ).where(role: %w[manager staff contractor]).pluck(:role)
      end
    end
  end
end
