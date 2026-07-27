# frozen_string_literal: true

require "test_helper"

module Events
  module StaffAssignments
    class SuspendTest < ActiveSupport::TestCase
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

      test "suspends the assignment and audits event.staff.suspended" do
        result = Events::StaffAssignments::Suspend.call(
          assignment: @assignment,
          actor: @actor
        )

        assert result.success?
        @assignment.reload
        assert_equal "suspended", @assignment.status

        audit = Core::AuditLog.where(auditable: @assignment, action: "event.staff.suspended").last
        assert audit, "expected an audit log entry for the suspension"
      end

      test "access_granted? becomes false after suspend" do
        assert Events::AuthorizationResolver.access_granted?(@user, @event)

        Events::StaffAssignments::Suspend.call(
          assignment: @assignment,
          actor: @actor
        )

        refute Events::AuthorizationResolver.access_granted?(@user, @event)
      end
    end
  end
end
