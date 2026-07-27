# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  class ScheduleChangedNotificationsJobTest < ActiveJob::TestCase
    include ActiveJob::TestHelper

    test "performing the job does not re-materialize the recurrence" do
      event = events_events(:ready_listing)
      Events::RecurrenceRule.create!(
        event:,
        rrule: "FREQ=WEEKLY;BYDAY=MO",
        timezone: "Africa/Addis_Ababa",
        dtstart_local: Time.zone.local(2026, 8, 1, 19),
        duration_seconds: 14_400,
        active: true
      )

      assert_no_enqueued_jobs only: Events::MaterializeRecurrenceJob do
        Events::ScheduleChangedNotificationsJob.perform_now(event.id)
      end
    end
  end
end
