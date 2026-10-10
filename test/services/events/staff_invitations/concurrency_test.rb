# frozen_string_literal: true

require "test_helper"

module Events
  module StaffInvitations
    class ConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @event = events_events(:ready_listing)
        @owner = core_users(:core_admin)
        @invitee = core_users(:attendee)
        @assignment_ids_before = @event.event_staff_assignments.where(user: @invitee).pluck(:id)
        @contact = "+251911999941"
      end

      teardown do
        invitation_ids = @invitation_ids || []
        assignment_ids = @event.event_staff_assignments.where(user: @invitee)
          .where.not(id: @assignment_ids_before).pluck(:id)
        Core::AuditLog.where(auditable_type: StaffInvitation.name, auditable_id: invitation_ids).delete_all
        Core::AuditLog.where(auditable_type: Events::EventStaffAssignment.name, auditable_id: assignment_ids).delete_all
        Core::OutboxEvent.where(aggregate_id: invitation_ids).delete_all
        Events::EventStaffAssignment.where(id: assignment_ids).delete_all
        StaffInvitation.where(id: invitation_ids).delete_all
      end

      test "concurrent creates for one event phone yield one pending invitation" do
        results = concurrently do |index|
          StaffInvitations::Create.call(
            event: @event,
            actor: @owner,
            phone: @contact,
            role: "staff",
            idempotency_key: "event-concurrent-create-#{index}",
            ip_address: "203.0.113.#{120 + index}"
          )
        end

        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count { |result| result.failure? && result.error.code == "invitation_already_pending" }
        invitation = results.find(&:success?).value.record
        @invitation_ids = [ invitation.id ]
        assert_equal 1, StaffInvitation.pending.where(event: @event).count
        assert_equal 1, Core::OutboxEvent.where(
          aggregate_id: invitation.id,
          event_type: "events.staff_invitation.delivery_requested"
        ).count
      end

      test "concurrent claims of one capability create exactly one event assignment" do
        created = StaffInvitations::Create.call(
          event: @event,
          actor: @owner,
          phone: @invitee.phone,
          role: "staff",
          idempotency_key: "event-concurrent-claim-create-#{SecureRandom.hex(5)}",
          ip_address: "203.0.113.130"
        )
        assert_predicate created, :success?, created.error&.message
        invitation = created.value.record
        @invitation_ids = [ invitation.id ]

        results = concurrently do |index|
          StaffInvitations::Claim.call(
            token: created.value.token,
            actor: @invitee,
            idempotency_key: "event-concurrent-claim-#{index}",
            ip_address: "203.0.113.#{131 + index}"
          )
        end

        assert_equal 1, results.count(&:success?)
        assert_equal "accepted", invitation.reload.status
        assert_equal 1, @event.event_staff_assignments.where(user: @invitee, role: "staff").count
        assert_equal 1, Core::AuditLog.where(
          auditable: invitation,
          action: "events.staff_invitation.accepted"
        ).count
      end

      private

      def concurrently(&operation)
        ready = Queue.new
        start = Queue.new
        results = Queue.new
        errors = Queue.new
        threads = 2.times.map do |index|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ready << true
              start.pop
              results << operation.call(index)
            end
          rescue StandardError => error
            errors << error
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        threads.each(&:join)
        raise errors.pop unless errors.empty?

        2.times.map { results.pop }
      end
    end
  end
end
