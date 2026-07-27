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
    end
  end
end
