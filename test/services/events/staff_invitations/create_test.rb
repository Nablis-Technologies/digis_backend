# frozen_string_literal: true

require "test_helper"

module Events
  module StaffInvitations
    class CreateTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @event = events_events(:ready_listing)
        @owner = core_users(:core_admin)
        @manager = core_users(:support)
        @outsider = core_users(:attendee)
        Events::EventStaffAssignment.create!(
          event: @event,
          organization: @event.organization,
          user: @manager,
          role: "manager",
          status: "active"
        )
      end

      test "owner creates a pending event-scoped staff invitation without creating a user or assignment" do
        phone = "+251911999201"
        user_count = Core::User.count
        assignment_count = @event.event_staff_assignments.count

        result = create_invitation(actor: @owner, phone:, role: "staff", key: "event-owner-staff")

        assert_predicate result, :success?, result.error&.message
        invitation = result.value.record
        assert_equal "pending", invitation.status
        assert_equal "staff", invitation.role
        assert_equal @event.id, invitation.event_id
        assert_equal "+251911999201", invitation.contact_ciphertext
        assert_equal 7.days.from_now.to_date, invitation.expires_at.to_date
        assert_equal assignment_count, @event.event_staff_assignments.count
        assert_equal user_count, Core::User.count
        assert_nil Core::User.find_by(phone: phone)

        outbox_event = Core::OutboxEvent.find_by!(
          event_type: "events.staff_invitation.delivery_requested",
          aggregate_id: invitation.id
        )
        assert_equal({
          "invitation_id" => invitation.id,
          "delivery_revision" => 1
        }, outbox_event.payload)
      end

      test "event manager may invite staff but not manager or contractor" do
        allowed = create_invitation(actor: @manager, phone: "+251911999202", role: "staff", key: "manager-staff")
        manager = create_invitation(actor: @manager, phone: "+251911999203", role: "manager", key: "manager-manager")
        contractor = create_invitation(actor: @manager, phone: "+251911999204", role: "contractor", key: "manager-contractor")

        assert_predicate allowed, :success?, allowed.error&.message
        assert_equal "invitation_forbidden", manager.error.code
        assert_equal "invitation_forbidden", contractor.error.code
      end

      test "organization owner may invite a manager or contractor but not a scanner" do
        manager = create_invitation(actor: @owner, phone: "+251911999205", role: "manager", key: "owner-manager")
        contractor = create_invitation(actor: @owner, phone: "+251911999206", role: "contractor", key: "owner-contractor")
        scanner = create_invitation(actor: @owner, phone: "+251911999207", role: "scanner", key: "owner-scanner")

        assert_predicate manager, :success?, manager.error&.message
        assert_predicate contractor, :success?, contractor.error&.message
        assert_equal "invalid_role", scanner.error.code
      end

      test "accepts optional future assignment expiry separately from invitation expiry" do
        assignment_expires_at = 2.days.from_now
        result = create_invitation(
          actor: @owner,
          phone: "+251911999208",
          role: "staff",
          key: "assignment-window",
          assignment_expires_at:
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal assignment_expires_at.to_i, result.value.record.assignment_expires_at.to_i
        assert_equal 7.days.from_now.to_date, result.value.record.expires_at.to_date

        expired_assignment = create_invitation(
          actor: @owner,
          phone: "+251911999209",
          role: "staff",
          key: "assignment-window-past",
          assignment_expires_at: 1.minute.ago
        )
        assert_equal "staff_invitation_window_invalid", expired_assignment.error.code
      end

      test "conflicts on duplicate pending phone and replays by idempotency key" do
        first = create_invitation(actor: @owner, phone: "+251911999210", role: "staff", key: "event-first")
        duplicate = create_invitation(actor: @owner, phone: "0911999210", role: "staff", key: "event-duplicate")

        assert_predicate first, :success?, first.error&.message
        assert_equal "invitation_already_pending", duplicate.error.code

        results = []
        operation = -> { results << create_invitation(actor: @owner, phone: "+251911999211", role: "staff", key: "event-replay") }
        counter = -> {
          Events::StaffInvitation.count +
            Core::OutboxEvent.where(event_type: "events.staff_invitation.delivery_requested").count
        }
        assert_idempotent(operation, counter:)
        assert results.last.value.replayed?
        assert_equal results.first.value.token, results.last.value.token
      end

      test "rejects unauthorized actors and a cancelled event" do
        unauthorized = create_invitation(actor: @outsider, phone: "+251911999212", role: "staff", key: "event-outsider")
        assert_equal "invitation_forbidden", unauthorized.error.code

        @event.update!(status: "cancelled")
        cancelled = create_invitation(actor: @owner, phone: "+251911999213", role: "staff", key: "event-cancelled")
        assert_equal "event_not_invitable", cancelled.error.code
      end

      test "expires an overdue pending invitation before creating its replacement" do
        expires_at = 1.minute.from_now
        prior = create_invitation(actor: @owner, phone: "+251911999214", role: "staff", key: "event-prior")
        prior.value.record.update!(expires_at:)

        replacement = create_invitation(
          actor: @owner,
          phone: "+251911999214",
          role: "staff",
          key: "event-replacement",
          at: expires_at + 1.second
        )

        assert_predicate replacement, :success?, replacement.error&.message
        assert_equal "expired", prior.value.record.reload.status
        assert_nil prior.value.record.claim_token_ciphertext
      end

      private

      def create_invitation(actor:, phone:, role:, key:, assignment_expires_at: nil, at: Time.current)
        Events::StaffInvitations::Create.call(
          event: @event,
          actor:,
          phone:,
          role:,
          assignment_expires_at:,
          idempotency_key: key,
          ip_address: "203.0.113.33",
          at:
        )
      end
    end
  end
end
