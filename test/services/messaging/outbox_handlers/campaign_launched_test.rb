# frozen_string_literal: true

require "test_helper"

module Messaging
  module OutboxHandlers
    class CampaignLaunchedTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      test "enqueues immediate fan-out from a launch event exactly once" do
        campaign = Campaign.create!(
          organization: organizations_organizations(:two), created_by: core_users(:super_admin),
          name: "Outbox launch #{SecureRandom.hex(4)}", channel: "email",
          timezone: "Africa/Addis_Ababa", status: "sending", message_body: "Hello"
        )
        event = Core::Outbox::Publish.call(
          topic: "messaging", event_type: "messaging.campaign.launched", aggregate: campaign,
          payload: { "campaign_id" => campaign.id, "credit_hold_id" => SecureRandom.uuid,
                      "dispatch_at" => nil, "launch_version" => campaign.launch_version },
          idempotency_key: "outbox-launch-#{campaign.id}"
        ).value

        assert_enqueued_with(job: Messaging::FanoutCampaignJob, args: [ campaign.id ]) do
          result = CampaignLaunched.call(event:)
          assert result.success?, result.error&.message
        end
      end
    end
  end
end
