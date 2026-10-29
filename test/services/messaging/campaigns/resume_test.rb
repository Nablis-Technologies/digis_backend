# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    class ResumeTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper
      include Core::AuditTestHelpers

      test "resumes a paused campaign and enqueues bounded fan-out once" do
        campaign = Campaign.create!(
          organization: organizations_organizations(:two), created_by: core_users(:super_admin),
          name: "Resume #{SecureRandom.hex(4)}", channel: "email", timezone: "Africa/Addis_Ababa",
          status: "paused", message_body: "Hello"
        )

        operation = -> { Resume.call(campaign:, actor: core_users(:super_admin), idempotency_key: "resume-1") }
        assert_enqueued_jobs 1, only: FanoutCampaignJob do
          assert_audit_idempotent(
            operation, action: "messaging.campaign.resumed", auditable_type: Campaign.name, auditable_id: campaign.id
          )
          result = operation.call

          assert result.success?, result.error&.message
          assert_equal "sending", campaign.reload.status
          assert_audit_logged(action: "messaging.campaign.resumed", auditable: campaign,
            actor: core_users(:super_admin))
          audit = Core::AuditLog.for_action("messaging.campaign.resumed").for_auditable(campaign).first
          expected_digest = Core::KeyedDigest.digest(
            namespace: "messaging-campaign-resumed-request",
            value: ActiveSupport::JSON.encode(campaign_id: campaign.id, actor_id: core_users(:super_admin).id)
          )
          assert_equal expected_digest, audit.metadata.fetch("request_digest")
        end
      end

      test "rejects resuming a campaign that is not paused" do
        campaign = Campaign.create!(
          organization: organizations_organizations(:two), created_by: core_users(:super_admin),
          name: "Resume invalid #{SecureRandom.hex(4)}", channel: "email", timezone: "Africa/Addis_Ababa",
          status: "draft", message_body: "Hello"
        )

        result = Resume.call(campaign:, actor: core_users(:super_admin), idempotency_key: "resume-invalid")

        assert_equal "campaign_invalid_state", result.error.code
      end

      test "records one audit for pausing a campaign and replaying its key" do
        campaign = Campaign.create!(
          organization: organizations_organizations(:two), created_by: core_users(:super_admin),
          name: "Pause audit #{SecureRandom.hex(4)}", channel: "email", timezone: "Africa/Addis_Ababa",
          status: "sending", message_body: "Hello"
        )
        actor = core_users(:super_admin)

        operation = -> { Pause.call(campaign:, actor:, idempotency_key: "pause-audit") }
        assert_audit_idempotent(
          operation, action: "messaging.campaign.paused", auditable_type: Campaign.name, auditable_id: campaign.id
        )
        result = operation.call

        assert result.success?, result.error&.message
        assert_audit_logged(action: "messaging.campaign.paused", auditable: campaign, actor:)
      end

      test "does not pause a campaign after another transition has canceled it" do
        organization = organizations_organizations(:two)
        actor = core_users(:super_admin)
        campaign = Campaign.create!(
          organization:, created_by: actor, name: "Pause race #{SecureRandom.hex(4)}", channel: "email",
          timezone: "Africa/Addis_Ababa", send_at: 1.minute.from_now, message_body: "Hello", status: "scheduled"
        )
        stale_campaign = Campaign.find(campaign.id)

        campaign.update_columns(status: "canceled", canceled_at: Time.current)
        result = Pause.call(campaign: stale_campaign, actor:, idempotency_key: "pause-race")

        assert_equal "campaign_invalid_state", result.error.code
        assert_equal "canceled", campaign.reload.status
      end
    end
  end
end
