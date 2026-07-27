# frozen_string_literal: true

require "test_helper"

module Events
  class RefreshDiscoveryJobTest < ActiveJob::TestCase
    test "records the discovery refresh timestamp for a published event" do
      event = events_events(:ready_listing)
      event.update!(status: "published", published_at: Time.current, discovery_refreshed_at: nil)

      Events::RefreshDiscoveryJob.perform_now(event.id)

      assert event.reload.discovery_refreshed_at.present?
    end

    test "silently ignores a missing event" do
      assert_nothing_raised do
        Events::RefreshDiscoveryJob.perform_now("00000000-0000-0000-0000-000000000000")
      end
    end

    test "does not refresh a non-published event" do
      event = events_events(:ready_listing)
      event.update!(status: "draft", published_at: nil, discovery_refreshed_at: nil)

      Events::RefreshDiscoveryJob.perform_now(event.id)

      assert_nil event.reload.discovery_refreshed_at
    end
  end
end
