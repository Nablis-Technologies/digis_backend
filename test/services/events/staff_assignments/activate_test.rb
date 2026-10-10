# frozen_string_literal: true

require "test_helper"

module Events
  module StaffAssignments
    class ActivateTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
        @user = core_users(:attendee)
        @organization = @event.organization
        Events::EventStaffAssignment.create!(
          event: @event, user: @user, organization: @organization, role: "staff", status: "active"
        )
        @suspended_manager = Events::EventStaffAssignment.create!(
          event: @event, user: @user, organization: @organization, role: "manager", status: "suspended"
        )
      end

      test "does not activate a second general role for the same event user" do
        result = Events::StaffAssignments::Activate.call(assignment: @suspended_manager, actor: @actor)

        refute_predicate result, :success?
        assert_equal "staff_assignment_role_change_required", result.error.code
        assert_equal "suspended", @suspended_manager.reload.status
        assert_equal [ "staff" ], @event.event_staff_assignments.where(
          user: @user, status: "active", role: %w[manager staff contractor]
        ).pluck(:role)
      end
    end
  end
end
