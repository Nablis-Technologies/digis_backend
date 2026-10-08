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
          actor: @actor,
          idempotency_key: "revoke-staff"
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
          actor: @actor,
          idempotency_key: "revoke-staff-access"
        )

        assert Events::EventStaffAssignment.exists?(id: id), "row should be retained after soft revoke"
        refute Events::AuthorizationResolver.access_granted?(@user, @event)
      end

      test "scanner revocation publishes a Ticketing cleanup event without coupling Events to Ticketing" do
        @assignment.update!(role: "scanner")

        result = revoke(key: "revoke-scanner-outbox")

        assert result.success?, result.error&.message
        outbox = Core::OutboxEvent.find_by!(
          event_type: "events.staff_assignment.revoked",
          aggregate_id: @assignment.id
        )
        assert_equal "events", outbox.topic
        assert_equal @assignment.id, outbox.payload.fetch("event_staff_assignment_id")
        assert_equal @actor.id, outbox.payload.fetch("actor_id")
      end

      test "scanner revocation replay writes one audit and one cleanup event" do
        @assignment.update!(role: "scanner")
        operation = -> { revoke(key: "revoke-scanner-replay") }
        counter = -> {
          Core::OutboxEvent.where(
            event_type: "events.staff_assignment.revoked",
            aggregate_id: @assignment.id
          ).count
        }

        assert_idempotent(operation, counter:)
        assert_equal 1, Core::AuditLog.where(
          auditable: @assignment, action: "event.staff.revoked"
        ).count
      end

      test "already revoked assignments are safe no-ops" do
        @assignment.update!(role: "scanner", status: "revoked")

        result = revoke(key: "revoke-scanner-already-revoked")

        assert result.success?, result.error&.message
        assert_equal 0, Core::AuditLog.where(
          auditable: @assignment, action: "event.staff.revoked"
        ).count
        assert_equal 0, Core::OutboxEvent.where(
          event_type: "events.staff_assignment.revoked",
          aggregate_id: @assignment.id
        ).count
      end

      private

      def revoke(key:)
        Events::StaffAssignments::Revoke.call(
          assignment: @assignment,
          actor: @actor,
          idempotency_key: key
        )
      end
    end
  end
end
