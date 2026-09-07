# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    module Audience
      class SnapshotTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = organizations_organizations(:two)
          @actor = core_users(:super_admin)
          @campaign = Campaign.create!(
            organization: @organization,
            created_by: @actor,
            name: "Snapshot #{SecureRandom.hex(4)}",
            channel: "sms",
            timezone: "Africa/Addis_Ababa",
            message_body: "Hello"
          )
          @list = CampaignContactList.create!(
            organization: @organization,
            created_by: @actor,
            name: "Snapshot list #{SecureRandom.hex(4)}"
          )
          ContactLists::Append.call(
            list: @list,
            rows: [ { phone_number: "+251911123456" } ],
            actor: @actor,
            idempotency_key: "snapshot-list-#{SecureRandom.hex(4)}"
          )
          @campaign.update!(metadata: { "audience_sources" => [
            { "type" => "contact_list", "id" => @list.id }
          ] })
        end

        test "creates a preparing snapshot and queues only its id" do
          assert_enqueued_with(job: Messaging::PrepareCampaignAudienceJob) do
            result = Snapshot.call(campaign: @campaign, actor: @actor, idempotency_key: "snapshot-1")

            assert result.success?
            assert_equal "preparing", result.value.status
          end

          assert_equal [ @campaign.audience_snapshot.id ], enqueued_jobs.last[:args]
        end

        test "rejects an unauthorized actor before creating a snapshot" do
          result = Snapshot.call(
            campaign: @campaign, actor: core_users(:attendee), idempotency_key: "snapshot-unauthorized"
          )

          assert_equal "unauthorized", result.error.code
          assert_nil @campaign.reload.audience_snapshot
        end

        test "late suppression marks the snapshot recipient ineligible" do
          digest = Core::KeyedDigest.digest(
            namespace: "messaging-campaign-contact-phone",
            value: "251911123456"
          )
          CampaignSuppression.create!(
            organization: @organization,
            channel: "sms",
            channel_address_digest: digest,
            source: "unsubscribe",
            reason: "stop",
            suppressed_at: Time.current,
            idempotency_key_digest: SecureRandom.hex(32)
          )

          snapshot = Snapshot.call(
            campaign: @campaign,
            actor: @actor,
            idempotency_key: "snapshot-suppression"
          ).value
          Messaging::PrepareCampaignAudienceJob.perform_now(snapshot.id)

          recipient = snapshot.reload.recipients.first
          assert_equal "suppressed", recipient.eligibility_status
          assert_equal "organization_suppression", recipient.eligibility_reason
          assert_equal 0, snapshot.eligible_quantity
        end
      end
    end
  end
end
