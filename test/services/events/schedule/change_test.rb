# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  module Schedule
    class ChangeTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      def setup
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
        @date1 = @event.event_dates.create!(starts_at: at(20), ends_at: at(22))
        @date2 = @event.event_dates.create!(starts_at: at(44), ends_at: at(46))
      end

      def at(hours)
        Time.zone.local(2026, 9, 1) + hours.hours
      end

      def one_change(date, new_start, new_end)
        [ { event_date_id: date.id, new_start_at: new_start, new_end_at: new_end } ]
      end

      def call(changes:, key: "k1")
        Events::Schedule::Change.call(
          event: @event, actor: @actor, changes: changes, idempotency_key: key
        )
      end

      test "records an immutable old/new snapshot for each changed date" do
        old_start = @date1.starts_at
        old_end = @date1.ends_at

        result = call(changes: one_change(@date1, at(23), at(25)))
        assert result.success?, result.error&.inspect

        change = Events::EventDateChange.find_by(event: @event, event_date_id: @date1.id)
        assert_not_nil change
        assert_in_delta old_start.to_f, change.old_start_at.to_f, 1
        assert_in_delta old_end.to_f, change.old_end_at.to_f, 1
        assert_in_delta at(23).to_f, change.new_start_at.to_f, 1
        assert_in_delta at(25).to_f, change.new_end_at.to_f, 1
        assert_equal "reschedule", change.change_type
      end

      test "applies the new times to the existing date without changing its id" do
        original_id = @date1.id

        call(changes: one_change(@date1, at(23), at(25)))

        assert_equal original_id, @date1.reload.id
        assert_in_delta at(23).to_f, @date1.starts_at.to_f, 1
        assert_in_delta at(25).to_f, @date1.ends_at.to_f, 1
        assert_equal 2, @event.event_dates.count
      end

    test "increments the event version once per change group" do
        assert_equal 1, @event.version
        initial_schedule_version = @event.reload.schedule_version

        result = call(changes: [
          { event_date_id: @date1.id, new_start_at: at(23), new_end_at: at(25) },
          { event_date_id: @date2.id, new_start_at: at(47), new_end_at: at(49) }
        ])
        assert result.success?, result.error&.inspect

        assert_equal 2, @event.reload.version
        assert_equal initial_schedule_version + 1, @event.reload.schedule_version
        assert_equal 2, Events::EventDateChange.where(event: @event).count
      end

      test "keeps earlier snapshots immutable across successive changes" do
        call(changes: one_change(@date1, at(23), at(25)), key: "k1")
        first = Events::EventDateChange.find_by(event: @event, event_date_id: @date1.id)
        frozen_new_start = first.new_start_at

        call(changes: one_change(@date1, at(30), at(32)), key: "k2")

        assert_equal frozen_new_start.to_f.round, first.reload.new_start_at.to_f.round
        assert_equal 2, Events::EventDateChange.where(event: @event, event_date_id: @date1.id).count
      end

      test "accumulates append-only history for the same event" do
        call(changes: one_change(@date1, at(23), at(25)), key: "k1")
        call(changes: one_change(@date1, at(30), at(32)), key: "k2")

        history = Events::EventDateChange.where(event: @event, event_date_id: @date1.id).order(:created_at)
        assert_equal 2, history.count
      end

      test "processes dates in a deterministic id order regardless of input order" do
        reversed = [ @date2, @date1 ].map do |date|
          { event_date_id: date.id, new_start_at: date.starts_at + 1.hour, new_end_at: date.ends_at + 1.hour }
        end

        result = call(changes: reversed)
        assert result.success?, result.error&.inspect
        assert_equal 2, Events::EventDateChange.where(event: @event).count
      end

      test "publishes exactly one schedule-changed outbox event" do
        assert_difference -> { Core::OutboxEvent.where(event_type: "events.schedule_changed").count }, 1 do
          call(changes: one_change(@date1, at(23), at(25)))
        end
      end

      test "is idempotent for a repeated idempotency key" do
        subject = -> { call(changes: one_change(@date1, at(23), at(25)), key: "same") }
        assert_audit_idempotent(
          subject,
          action: "event.schedule.changed",
          auditable_type: "Events::Event",
          auditable_id: @event.id
        )
      end

      test "enqueues the schedule-changed notifications job" do
        assert_enqueued_with(job: Events::ScheduleChangedNotificationsJob) do
          call(changes: one_change(@date1, at(23), at(25)))
        end
      end

      test "writes an audit entry for the schedule change" do
        result = call(changes: one_change(@date1, at(23), at(25)))
        assert result.success?
        assert Core::AuditLog.exists?(
          action: "event.schedule.changed",
          auditable_type: "Events::Event",
          auditable_id: @event.id
        )
      end

      test "rejects a change referencing a date that does not belong to the event" do
        foreign_id = Events::EventDate.create!(event: events_events(:draft_concert), starts_at: at(1), ends_at: at(2)).id

        result = call(changes: one_change(Events::EventDate.new(id: foreign_id), at(23), at(25)))
        assert result.failure?
        assert_equal "invalid_dates", result.error.code
        assert_equal :unprocessable_entity, result.error.status
      end
    end
  end
end
