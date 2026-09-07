# frozen_string_literal: true

require "test_helper"

module Finance
  class CompleteEventTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include PayoutTestHelpers

    setup do
      setup_payout_context(status: "published")
      @event.event_dates.create!(
        starts_at: @now - 2.days,
        ends_at: @now - 1.day,
        status: "completed"
      )
    end

    test "completes the event and schedules maturity after the safety buffer" do
      assert_enqueued_with(job: Finance::MatureEventFundsJob, args: [ @event.id ]) do
        result = Finance::CompleteEvent.call(
          event: @event,
          actor: core_users(:super_admin),
          idempotency_key: "complete-event-1",
          at: @now
        )

        assert_predicate result, :success?, result.error&.message
      end

      assert_equal "completed", @event.reload.status
      assert_equal @now, @event.completed_at
      assert_equal 1, Core::AuditLog.where(
        auditable_type: "Events::Event",
        auditable_id: @event.id,
        action: "event.completed"
      ).count
    end

    test "completes ended scheduled dates before completing the event" do
      @event.event_dates.update_all(status: "scheduled")
      schedule_version = @event.schedule_version

      assert_enqueued_with(job: Finance::MatureEventFundsJob, args: [ @event.id ]) do
        result = Finance::CompleteEvent.call(
          event: @event,
          actor: core_users(:super_admin),
          idempotency_key: "complete-ended-scheduled-event",
          at: @now
        )

        assert_predicate result, :success?, result.error&.message
      end

      assert_equal "completed", @event.reload.status
      assert_equal "completed", @event.event_dates.first.reload.status
      assert_equal schedule_version + 1, @event.schedule_version
      assert_equal 1, Core::AuditLog.where(
        action: "event.date.completed", auditable_id: @event.id
      ).count
    end

    test "rejects an event with an unfinished scheduled date" do
      @event.event_dates.update_all(status: "scheduled", starts_at: @now, ends_at: @now + 1.day)

      result = Finance::CompleteEvent.call(
        event: @event,
        actor: core_users(:super_admin),
        idempotency_key: "complete-event-unfinished",
        at: @now
      )

      assert_predicate result, :failure?
      assert_equal "event_dates_incomplete", result.error.code
      assert_equal "published", @event.reload.status
      assert_nil @event.completed_at
    end

    test "leaves postponed dates untouched when completion is attempted" do
      @event.event_dates.update_all(status: "postponed")

      result = Finance::CompleteEvent.call(
        event: @event,
        actor: core_users(:super_admin),
        idempotency_key: "complete-postponed-event",
        at: @now
      )

      assert_predicate result, :failure?
      assert_equal "event_dates_incomplete", result.error.code
      assert_equal "postponed", @event.event_dates.first.reload.status
      assert_equal "published", @event.reload.status
    end

    test "allows cancelled dates and rejects an unauthorized actor" do
      @event.event_dates.update_all(status: "cancelled")

      unauthorized = Finance::CompleteEvent.call(
        event: @event,
        actor: core_users(:attendee),
        idempotency_key: "complete-event-unauthorized",
        at: @now
      )

      assert_predicate unauthorized, :failure?
      assert_equal "unauthorized", unauthorized.error.code

      result = Finance::CompleteEvent.call(
        event: @event,
        actor: core_users(:super_admin),
        idempotency_key: "complete-event-cancelled-date",
        at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "completed", @event.reload.status
    end

    test "replays the same completion without a second audit or job" do
      command = -> do
        Finance::CompleteEvent.call(
          event: @event,
          actor: core_users(:super_admin),
          idempotency_key: "complete-event-replay",
          at: @now
        )
      end

      first = nil
      assert_enqueued_with(job: Finance::MatureEventFundsJob, args: [ @event.id ]) do
        first = command.call
      end
      second = nil
      assert_no_enqueued_jobs do
        second = command.call
      end

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal first.value.id, second.value.id
      assert_equal 1, Core::AuditLog.where(action: "event.completed", auditable_id: @event.id).count
    end

    test "allows only the fixed scheduler source for automatic completion" do
      @event.event_dates.update_all(status: "scheduled")
      key = "scheduled-completion-#{@event.id}"

      assert_enqueued_with(job: Finance::MatureEventFundsJob, args: [ @event.id ]) do
        result = Finance::CompleteEvent.call(
          event: @event, actor: nil, source: "scheduler", idempotency_key: key, at: @now
        )

        assert_predicate result, :success?, result.error&.message
      end

      assert_equal "scheduler", Core::AuditLog.find_by(
        audit_key: "finance-event-completed-#{Core::IdempotencyKey.new(key).digest}"
      ).metadata.fetch("source")

      assert_no_enqueued_jobs do
        replay = Finance::CompleteEvent.call(
          event: @event, actor: nil, source: "scheduler", idempotency_key: key, at: @now
        )

        assert_predicate replay, :success?, replay.error&.message
      end

      unauthorized = Finance::CompleteEvent.call(
        event: @event,
        actor: nil,
        source: "manual",
        idempotency_key: "scheduler-source-invalid",
        at: @now
      )

      assert_predicate unauthorized, :failure?
      assert_equal "unauthorized", unauthorized.error.code
    end
  end
end
