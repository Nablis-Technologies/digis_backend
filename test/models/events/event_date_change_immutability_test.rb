# frozen_string_literal: true

require "test_helper"

module Events
  # Exercises the DB-level append-only trigger on the schedule-change ledger.
  # AR callbacks are bypassed via update_all / raw SQL to prove the storage
  # layer rejects both UPDATE and DELETE regardless of the writer.
  class EventDateChangeImmutabilityTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @event_date = Events::EventDate.create!(
        event: @event,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 2.hours,
        status: "scheduled"
      )
      @change = Events::EventDateChange.create!(
        event: @event, event_date: @event_date, change_type: "reschedule",
        old_start_at: 1.day.from_now, old_end_at: 1.day.from_now + 2.hours,
        new_start_at: 2.days.from_now, new_end_at: 2.days.from_now + 2.hours,
        scheduled_by: core_users(:super_admin)
      )
    end

    test "event date change is append-only: UPDATE rejected at the DB layer" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Events::EventDateChange.where(id: @change.id).update_all(change_type: "reschedule")
      end
    end

    test "event date change is append-only: DELETE rejected at the DB layer" do
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.lease_connection.execute(
          "DELETE FROM events_event_date_changes WHERE id = '#{@change.id}'")
      end
    end

    test "event date change can still be appended (INSERT)" do
      assert_nothing_raised do
        Events::EventDateChange.create!(
          event: @event, event_date: @event_date, change_type: "reschedule",
          old_start_at: 2.days.from_now, old_end_at: 2.days.from_now + 2.hours,
          new_start_at: 3.days.from_now, new_end_at: 3.days.from_now + 2.hours,
          scheduled_by: core_users(:super_admin)
        )
      end
    end
  end
end
