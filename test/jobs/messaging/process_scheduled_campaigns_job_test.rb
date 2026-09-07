# frozen_string_literal: true

require "test_helper"

module Messaging
  class ProcessScheduledCampaignsJobTest < ActiveJob::TestCase
    test "moves due scheduled campaigns to sending and enqueues only the id" do
      campaign = Campaign.create!(
        organization: organizations_organizations(:two), created_by: core_users(:super_admin),
        name: "Scheduled #{SecureRandom.hex(4)}", channel: "email", timezone: "Africa/Addis_Ababa",
        status: "scheduled", send_at: 1.minute.ago, message_body: "Hello"
      )

      assert_enqueued_with(job: Messaging::FanoutCampaignJob, args: [ campaign.id ]) do
        ProcessScheduledCampaignsJob.perform_now
      end

      assert_equal "sending", campaign.reload.status
    end
  end
end
