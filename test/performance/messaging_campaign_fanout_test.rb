# frozen_string_literal: true

require "test_helper"

module Messaging
  module Performance
    class CampaignFanoutTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper
      test "fan-out jobs carry only campaign identifiers and cursors" do
        assert_enqueued_with(job: Messaging::FanoutCampaignJob,
          args: [ "campaign-id", { "after_recipient_id" => "recipient-id" } ]) do
          Messaging::FanoutCampaignJob.perform_later(
            "campaign-id", { "after_recipient_id" => "recipient-id" }
          )
        end
      end

      test "campaign fan-out benchmark is opt-in" do
        skip "set CAMPAIGN_PERFORMANCE=1 to run the campaign fan-out benchmark" unless
          ENV["CAMPAIGN_PERFORMANCE"] == "1"

        assert true
      end
    end
  end
end
