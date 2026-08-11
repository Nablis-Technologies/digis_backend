# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ExpireAttendeeExportsJobTest < ActiveJob::TestCase
    include Ticketing::AttendeeExportTestHelpers

    test "expires due exports in a bounded batch" do
      due = create_export(
        event: events_events(:ready_listing),
        actor: core_users(:super_admin),
        overrides: { status: "ready", data_cutoff_at: 2.days.ago, expires_at: 1.minute.ago }
      )
      later = create_export(
        event: events_events(:ready_listing),
        actor: core_users(:super_admin),
        overrides: { status: "ready", expires_at: 1.hour.from_now }
      )

      Ticketing::ExpireAttendeeExportsJob.perform_now(1)

      assert_equal "expired", due.reload.status
      assert_equal "ready", later.reload.status
    end
  end
end
