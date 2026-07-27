# frozen_string_literal: true

require "test_helper"

module Events
  module StaffAssignments
    class RevokeTest < ActiveSupport::TestCase
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

      test "revokes the assignment (status revoked) and audits event.staff.revoked" do
        result = Events::StaffAssignments::Revoke.call(
          assignment: @assignment,
          actor: @actor
        )

        assert result.success?
        @assignment.reload
        assert_equal "revoked", @assignment.status

        audit = Core::AuditLog.where(auditable: @assignment, action: "event.staff.revoked").last
        assert audit, "expected an audit log entry for the revocation"
      end

      test "row is retained after revoke and access_granted? is false" do
        id = @assignment.id

        Events::StaffAssignments::Revoke.call(
          assignment: @assignment,
          actor: @actor
        )

        assert Events::EventStaffAssignment.exists?(id: id), "row should be retained after soft revoke"
        refute Events::AuthorizationResolver.access_granted?(@user, @event)
      end
    end
  end
end
