# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  module Recurrence
    class MaterializeRecurrenceJobTest < ActiveJob::TestCase
      include ActiveJob::TestHelper

      test "materializes occurrences for a persisted rule" do
        event = events_events(:ready_listing)
        rule = Events::RecurrenceRule.create!(
          event:,
          rrule: "FREQ=DAILY;COUNT=3",
          timezone: "Africa/Addis_Ababa",
          dtstart_local: Time.zone.local(2026, 8, 1, 20, 0, 0),
          duration_seconds: 3600
        )

        assert_difference -> { Events::EventDate.count }, 3 do
          MaterializeRecurrenceJob.perform_now(rule.id)
        end

        assert_equal 3, event.reload.event_dates.count
      end

      test "does nothing for a missing rule" do
        assert_no_difference -> { Events::EventDate.count } do
          MaterializeRecurrenceJob.perform_now("00000000-0000-0000-0000-000000000000")
        end
      end
    end
  end
end
