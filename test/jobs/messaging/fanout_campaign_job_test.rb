# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class FanoutCampaignJobTest < ActiveJob::TestCase
    test "processes a bounded page and re-enqueues the cursor" do
      campaign, account, rate = build_campaign_with_recipients(101)
      hold = Campaigns::CreditHolds::Reserve.call(
        account:, organization: campaign.organization, rate_version: rate,
        source_type: "Messaging::Campaign", source_id: campaign.id, quantity: 101,
        idempotency_key: "fanout-hold"
      ).value
      campaign.update_columns(status: "sending")
      register_fake_provider

      assert_enqueued_with(job: Messaging::FanoutCampaignJob) do
        FanoutCampaignJob.perform_now(campaign.id)
      end

      assert_equal 100, campaign.reload.deliveries.where(status: "delivered").count
      follow_up = enqueued_jobs.find { |job| job[:job] == Messaging::FanoutCampaignJob }
      assert follow_up
      assert_equal campaign.id, follow_up[:args].first
      assert follow_up[:args].last.fetch("after_recipient_id").present?
      assert_equal 100, hold.reload.allocations.count
    end

    test "completes the campaign and finalizes its hold after the final page" do
      campaign, account, rate = build_campaign_with_recipients(1)
      hold = Campaigns::CreditHolds::Reserve.call(
        account:, organization: campaign.organization, rate_version: rate,
        source_type: "Messaging::Campaign", source_id: campaign.id, quantity: 1,
        idempotency_key: "fanout-final-hold"
      ).value
      campaign.update_columns(status: "sending")
      register_fake_provider

      FanoutCampaignJob.perform_now(campaign.id)

      assert_equal "completed", campaign.reload.status
      assert campaign.completed_at
      assert_equal "consumed", hold.reload.status
      assert_equal "campaign_completed", hold.resolution_code
    end

    test "completes an empty campaign and releases its unused hold" do
      campaign, account, rate = build_campaign_with_recipients(0)
      hold = Campaigns::CreditHolds::Reserve.call(
        account:, organization: campaign.organization, rate_version: rate,
        source_type: "Messaging::Campaign", source_id: campaign.id, quantity: 1,
        idempotency_key: "fanout-empty-hold"
      ).value
      campaign.update_columns(status: "sending")

      FanoutCampaignJob.perform_now(campaign.id)

      assert_equal "completed", campaign.reload.status
      assert_equal "released", hold.reload.status
      assert_equal "campaign_completed", hold.resolution_code
    end

    test "retries due pending deliveries instead of stranding the campaign" do
      campaign, account, rate = build_campaign_with_recipients(1)
      Campaigns::CreditHolds::Reserve.call(
        account:, organization: campaign.organization, rate_version: rate,
        source_type: "Messaging::Campaign", source_id: campaign.id, quantity: 1,
        idempotency_key: "fanout-retry-hold"
      )
      campaign.update_columns(status: "sending")
      register_retryable_provider

      FanoutCampaignJob.perform_now(campaign.id)

      delivery = campaign.reload.deliveries.first
      assert_equal "pending", delivery.status
      assert delivery.next_attempt_at
      assert enqueued_jobs.any? { |job| job[:job] == Messaging::FanoutCampaignJob }

      delivery.update_columns(next_attempt_at: 1.minute.ago)
      register_fake_provider
      FanoutCampaignJob.perform_now(campaign.id)

      assert_equal "completed", campaign.reload.status
      assert_equal "delivered", delivery.reload.status
    end

    test "does not move the fresh-recipient cursor backward for a retry batch" do
      campaign, account, rate = build_campaign_with_recipients(200)
      hold = Campaigns::CreditHolds::Reserve.call(
        account:, organization: campaign.organization, rate_version: rate,
        source_type: "Messaging::Campaign", source_id: campaign.id, quantity: 200,
        idempotency_key: "fanout-cursor-hold"
      ).value
      recipients = campaign.recipients.order(:id).to_a
      deliveries = recipients.first(100).map do |recipient|
        CampaignDelivery.create!(
          campaign:, campaign_recipient: recipient, channel: "sms", status: "pending",
          next_attempt_at: 1.minute.ago,
          idempotency_key_digest: Digest::SHA256.hexdigest("cursor-delivery-#{recipient.id}")
        )
      end
      Campaigns::CreditHolds::AllocateBatch.call(reservation: hold, deliveries:)
      campaign.update_columns(status: "sending")
      register_fake_provider
      cursor = recipients.fetch(149).id

      FanoutCampaignJob.perform_now(campaign.id, { "after_recipient_id" => cursor })

      follow_up = enqueued_jobs.find { |job| job[:job] == Messaging::FanoutCampaignJob }
      assert follow_up
      assert_equal cursor, follow_up[:args].last.fetch("after_recipient_id")
    end

    test "advances the fresh cursor without waiting for a future retry" do
      campaign, account, rate = build_campaign_with_recipients(200)
      hold = Campaigns::CreditHolds::Reserve.call(
        account:, organization: campaign.organization, rate_version: rate,
        source_type: "Messaging::Campaign", source_id: campaign.id, quantity: 200,
        idempotency_key: "fanout-future-retry-hold"
      ).value
      recipients = campaign.recipients.order(:id).to_a
      retry_delivery = CampaignDelivery.create!(
        campaign:, campaign_recipient: recipients.fetch(150), channel: "sms", status: "pending",
        next_attempt_at: 1.hour.from_now,
        idempotency_key_digest: Digest::SHA256.hexdigest("future-retry-delivery")
      )
      Campaigns::CreditHolds::Allocate.call(
        reservation: hold, delivery: retry_delivery, quantity: 1, idempotency_key: "future-retry-allocation"
      )
      campaign.update_columns(status: "sending")
      register_fake_provider

      FanoutCampaignJob.perform_now(campaign.id)

      follow_up = enqueued_jobs.find { |job| job[:job] == Messaging::FanoutCampaignJob }
      assert follow_up
      assert_equal recipients.fetch(99).id, follow_up[:args].last.fetch("after_recipient_id")
      assert_nil follow_up[:at]
    end

    test "resets the cursor when recovery finds unclaimed recipients before it" do
      campaign, account, rate = build_campaign_with_recipients(200)
      Campaigns::CreditHolds::Reserve.call(
        account:, organization: campaign.organization, rate_version: rate,
        source_type: "Messaging::Campaign", source_id: campaign.id, quantity: 200,
        idempotency_key: "fanout-recovery-cursor-hold"
      )
      recipients = campaign.recipients.order(:id).to_a
      campaign.update_columns(status: "sending")
      register_fake_provider

      FanoutCampaignJob.perform_now(campaign.id, { "after_recipient_id" => recipients.fetch(150).id })

      follow_up = enqueued_jobs.find { |job| job[:job] == Messaging::FanoutCampaignJob }
      assert follow_up
      assert_nil follow_up[:args].last["after_recipient_id"]
    end

    private

    def build_campaign_with_recipients(count)
      organization = organizations_organizations(:two)
      actor = core_users(:super_admin)
      account = CreditAccount.create!(organization:, channel: "sms")
      rate = CreditRateVersion.create!(
        organization:, channel: "sms", version: 1, currency: "ETB", unit_price_minor: 1,
        volume_tiers: [], effective_from: 1.hour.ago, status: "active",
        idempotency_key_digest: Digest::SHA256.hexdigest("fanout-rate-#{SecureRandom.hex(4)}"),
        request_digest: Digest::SHA256.hexdigest("fanout-request-#{SecureRandom.hex(4)}"), activated_at: 1.hour.ago
      )
      CreditLedgerEntry.create!(
        credit_account: account, entry_type: "top_up", quantity: [ count, 1 ].max, available_delta: [ count, 1 ].max,
        idempotency_key_digest: Digest::SHA256.hexdigest("fanout-grant-#{SecureRandom.hex(4)}"), metadata: {}
      )
      campaign = Campaign.create!(
        organization:, created_by: actor, name: "Fanout #{SecureRandom.hex(4)}", channel: "sms",
        timezone: "Africa/Addis_Ababa", message_body: "Hello"
      )
      snapshot = CampaignAudienceSnapshot.create!(
        campaign:, source_spec: { "sources" => [] }, status: "ready", total_count: count,
        processed_count: count, eligible_quantity: count, completed_at: Time.current
      )
      count.times do |index|
        recipient = CampaignRecipient.create!(
          campaign:, audience_snapshot: snapshot, channel: "sms",
          channel_address: "+2519#{format("%08d", index)}",
          channel_address_digest: Digest::SHA256.hexdigest("fanout-recipient-#{index}"),
          source_type: "contact_list", eligibility_status: "eligible", quantity: 1
        )
        recipient
      end
      [ campaign, account, rate ]
    end

    def register_fake_provider
      adapter = Class.new(Messaging::Providers::Adapter) do
        def deliver_campaign(**)
          Messaging::Providers::DeliveryResult.delivered(provider: "fake")
        end
      end.new
      Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)
    end

    def register_retryable_provider
      adapter = Class.new(Messaging::Providers::Adapter) do
        def deliver_campaign(**)
          Messaging::Providers::DeliveryResult.retryable(provider: "fake", failure_code: "rate_limited")
        end
      end.new
      Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)
    end
  end
end
