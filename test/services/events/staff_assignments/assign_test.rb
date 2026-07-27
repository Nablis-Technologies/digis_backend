# frozen_string_literal: true

require "test_helper"

module Events
  module StaffAssignments
    class AssignTest < ActiveSupport::TestCase
      def setup
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
        @user = core_users(:attendee)
        @organization = organizations_organizations(:two)
      end

      test "assigns an active staff member and audits event.staff.assigned" do
        result = Events::StaffAssignments::Assign.call(
          event: @event,
          actor: @actor,
          user: @user,
          organization: @organization,
          role: "staff"
        )

        assert result.success?
        assignment = result.value
        assert assignment.is_a?(Events::EventStaffAssignment)
        assert_equal "active", assignment.status
        assert_equal @event.id, assignment.event_id
        assert_equal @user.id, assignment.user_id
        assert_equal "staff", assignment.role

        audit = Core::AuditLog.where(auditable: assignment, action: "event.staff.assigned").last
        assert audit, "expected an audit log entry for the assignment"
        assert_equal @actor.id, audit.actor_id
      end

      test "duplicate user+event+type returns failure with code duplicate_assignment" do
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @user,
          organization: @organization,
          role: "staff",
          status: "active"
        )

        result = Events::StaffAssignments::Assign.call(
          event: @event,
          actor: @actor,
          user: @user,
          organization: @organization,
          role: "staff"
        )

        refute result.success?
        assert_equal "duplicate_assignment", result.error.code
      end

      test "invalid role returns failure with code invalid_role" do
        result = Events::StaffAssignments::Assign.call(
          event: @event,
          actor: @actor,
          user: @user,
          organization: @organization,
          role: "wizard"
        )

        refute result.success?
        assert_equal "invalid_role", result.error.code
      end

      test "insufficient permission returns failure with code forbidden" do
        result = Events::StaffAssignments::Assign.call(
          event: @event,
          actor: @user,
          user: @user,
          organization: @organization,
          role: "staff"
        )

        refute result.success?
        assert_equal "forbidden", result.error.code
      end
    end
  end
end
