# frozen_string_literal: true

require "test_helper"

module Links
  class PurgeExpiredClicksJobTest < ActiveJob::TestCase
    setup do
      @link = Links::ShortLink.create!(
        slug: "retention-target-#{SecureRandom.hex(4)}",
        target_type: "event", target_id: events_events(:ready_listing).id,
        canonical: true, click_count: 2
      )
    end

    teardown do
      Links::ShortLinkClick.delete_all
      Links::ShortLink.delete_all
    end

    test "deletes only click details older than retention and preserves the aggregate link" do
      now = Time.current
      expired = Links::ShortLinkClick.create!(short_link: @link, clicked_at: 91.days.ago, country: "ET")
      recent = Links::ShortLinkClick.create!(short_link: @link, clicked_at: 89.days.ago, country: "ET")

      result = Links::PurgeExpiredClicksJob.perform_now(retention_days: 90, now:)

      assert_equal 1, result[:deleted]
      refute Links::ShortLinkClick.exists?(expired.id)
      assert Links::ShortLinkClick.exists?(recent.id)
      assert_equal [ @link.target_type, @link.target_id, 2 ], @link.reload.values_at(:target_type, :target_id, :click_count)
    end

    test "processes retention rows in bounded batches" do
      now = Time.current
      2.times do |index|
        Links::ShortLinkClick.create!(
          short_link: @link, clicked_at: (91 + index).days.ago, country: "ET"
        )
      end

      result = Links::PurgeExpiredClicksJob.perform_now(retention_days: 90, batch_size: 1, now:)

      assert_equal 2, result[:deleted]
      assert_equal 0, @link.reload.clicks.count
      assert_equal 2, @link.click_count
    end

    test "production recurring schedule invokes the purge job" do
      schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
        .fetch("production").fetch("purge_expired_short_link_clicks")

      assert_equal "Links::PurgeExpiredClicksJob", schedule.fetch("class")
      assert_equal "every day at 3am", schedule.fetch("schedule")
    end
  end
end
