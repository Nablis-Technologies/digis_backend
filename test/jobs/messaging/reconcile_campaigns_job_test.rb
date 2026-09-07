# frozen_string_literal: true

require "digest"
require "stringio"
require "test_helper"

module Messaging
  class ReconcileCampaignsJobTest < ActiveJob::TestCase
    test "requeues a stale delivery without duplicating its allocation" do
      campaign, delivery = build_delivery(status: "processing")
      delivery.update_columns(claimed_at: 6.minutes.ago)

      ReconcileCampaignsJob.perform_now

      assert_equal "pending", delivery.reload.status
      assert_equal 1, delivery.credit_allocation.reload.quantity
      assert_equal campaign.id, delivery.campaign_id
    end

    test "hands a stale delivery from a terminal campaign to recovery" do
      campaign, delivery = build_delivery(status: "processing")
      delivery.update_columns(claimed_at: 6.minutes.ago, attempts: 1)
      campaign.update_columns(status: "canceled", canceled_at: Time.current)

      assert_enqueued_with(job: Messaging::RecoverCampaignDeliveryJob, args: [ delivery.id ]) do
        ReconcileCampaignsJob.perform_now
      end

      assert_equal "processing", delivery.reload.status
      assert_equal "allocated", delivery.credit_allocation.reload.status
    end

    test "refunds a never-attempted delivery when its campaign is canceled" do
      campaign, delivery = build_delivery(status: "pending")
      campaign.update_columns(status: "canceled", canceled_at: Time.current)

      ReconcileCampaignsJob.perform_now

      assert_equal "failed", delivery.reload.status
      assert_equal "campaign_aborted", delivery.failure_code
      assert_equal "refunded", delivery.credit_allocation.reload.status
      assert_equal "consumed", delivery.credit_allocation.credit_reservation.reload.status
    end

    test "recovery retries a stale provider delivery with its original idempotency key" do
      _campaign, delivery = build_delivery(status: "processing")
      delivery.update_columns(claimed_at: 6.minutes.ago, attempts: 1)
      captured_key = nil
      adapter = Class.new(Messaging::Providers::Adapter) do
        define_method(:initialize) { |key| @key = key }

        define_method(:deliver_campaign) do |idempotency_key:, **|
          @key << idempotency_key
          Messaging::Providers::DeliveryResult.delivered(provider: "fake")
        end
      end.new(captured_key = [])
      registry = Rails.application.config.x.messaging_provider_registry
      previous = registry.fetch(channel: "email")
      begin
        registry.register(channel: "email", adapter:)
        RecoverCampaignDeliveryJob.perform_now(delivery.id)
      ensure
        registry.register(channel: "email", adapter: previous) if previous
        registry.unregister(channel: "email") unless previous
      end

      assert_equal [ delivery.idempotency_key_digest ], captured_key
      assert_equal "delivered", delivery.reload.status
      assert_equal "consumed", delivery.credit_allocation.reload.status
    end

    test "re-enqueues sending campaigns with due pending work" do
      campaign, delivery = build_delivery(status: "pending")
      campaign.update_columns(status: "sending")
      delivery.update_columns(next_attempt_at: 1.minute.ago)

      assert_enqueued_with(job: Messaging::FanoutCampaignJob, args: [ campaign.id ]) do
        ReconcileCampaignsJob.perform_now
      end
    end

    test "re-enqueues sending campaigns whose deliveries are terminal" do
      campaign, delivery = build_delivery(status: "pending")
      allocation = delivery.credit_allocation
      settlement = Campaigns::CreditHolds::Settle.call(
        allocation:, outcome: :delivered, idempotency_key: "reconcile-terminal-settle"
      )
      assert settlement.success?, settlement.error&.message
      delivery.update_columns(status: "delivered", delivered_at: Time.current)
      campaign.update_columns(status: "sending")

      assert_enqueued_with(job: Messaging::FanoutCampaignJob, args: [ campaign.id ]) do
        ReconcileCampaignsJob.perform_now
      end
    end

    test "finalizes a canceled campaign hold after its in-flight allocation settles" do
      campaign, delivery = build_delivery(status: "pending")
      hold = delivery.credit_allocation.credit_reservation
      campaign.update_columns(status: "canceled", canceled_at: Time.current)
      settlement = Campaigns::CreditHolds::Settle.call(
        allocation: delivery.credit_allocation, outcome: :failed, reason: "provider_failed",
        idempotency_key: "reconcile-canceled-settle"
      )
      assert settlement.success?, settlement.error&.message

      ReconcileCampaignsJob.perform_now

      assert_equal "consumed", hold.reload.status
      assert_equal "campaign_aborted", hold.resolution_code
    end

    test "finalizes a failed campaign hold after its allocation settles" do
      campaign, delivery = build_delivery(status: "pending")
      hold = delivery.credit_allocation.credit_reservation
      settlement = Campaigns::CreditHolds::Settle.call(
        allocation: delivery.credit_allocation, outcome: :failed, reason: "provider_failed",
        idempotency_key: "reconcile-failed-settle"
      )
      assert settlement.success?, settlement.error&.message
      campaign.update_columns(status: "failed")

      ReconcileCampaignsJob.perform_now

      assert_equal "consumed", hold.reload.status
      assert_equal "campaign_failed", hold.resolution_code
    end

    test "purges old campaign message and contact material but keeps hold evidence" do
      campaign, delivery = build_delivery(status: "delivered")
      hold = delivery.credit_allocation.credit_reservation
      old = 91.days.ago
      campaign.update_columns(status: "completed", completed_at: old, updated_at: old,
        message_body_ciphertext: campaign.message_body_ciphertext, message_subject_ciphertext: "subject")
      contact = CampaignContactList.create!(
        organization: campaign.organization, created_by: core_users(:super_admin),
        name: "Old contacts #{SecureRandom.hex(4)}"
      ).entries.create!(
        phone_number: "+251911123456", phone_digest: Digest::SHA256.hexdigest("old-phone"), status: "removed"
      )
      contact.update_columns(created_at: old, updated_at: old)

      PurgeCampaignPayloadsJob.perform_now

      assert_nil campaign.reload.message_body_ciphertext
      assert_nil contact.reload.phone_number_ciphertext
      assert hold.reload.persisted?
    end

    test "preserves old entries in active contact lists" do
      organization = organizations_organizations(:two)
      list = CampaignContactList.create!(
        organization:, created_by: core_users(:super_admin), name: "Purge batch #{SecureRandom.hex(4)}"
      )
      old = 91.days.ago
      entries = 101.times.map do |index|
        list.entries.create!(
          phone_number: "+251911#{format("%06d", index)}",
          phone_digest: Digest::SHA256.hexdigest("active-entry-#{index}"), status: "active"
        )
      end
      CampaignContactListEntry.where(id: entries.map(&:id)).update_all(updated_at: old)

      PurgeCampaignPayloadsJob.perform_now

      assert_equal 101, CampaignContactListEntry.where(id: entries.map(&:id))
        .where.not(phone_number_ciphertext: nil).count
    end

    test "purges old removed entries in bounded batches" do
      organization = organizations_organizations(:two)
      list = CampaignContactList.create!(
        organization:, created_by: core_users(:super_admin), name: "Removed purge #{SecureRandom.hex(4)}"
      )
      old = 91.days.ago
      entries = 101.times.map do |index|
        list.entries.create!(
          phone_number: "+251911#{format("%06d", index)}",
          phone_digest: Digest::SHA256.hexdigest("removed-entry-#{index}"), status: "removed"
        )
      end
      CampaignContactListEntry.where(id: entries.map(&:id)).update_all(updated_at: old)

      PurgeCampaignPayloadsJob.perform_now

      purged = CampaignContactListEntry.where(id: entries.map(&:id)).where(phone_number_ciphertext: nil).count
      remaining = CampaignContactListEntry.where(id: entries.map(&:id)).where.not(phone_number_ciphertext: nil).count
      assert_equal 100, purged
      assert_equal 1, remaining
    end

    test "advances old imports after scheduling payload purge" do
      list = CampaignContactList.create!(
        organization: organizations_organizations(:two), created_by: core_users(:super_admin),
        name: "Purge import #{SecureRandom.hex(4)}"
      )
      import = list.imports.create!(
        created_by: core_users(:super_admin), status: "completed", filename: "contacts.csv",
        idempotency_key_digest: Digest::SHA256.hexdigest("purge-import"),
        request_digest: Digest::SHA256.hexdigest("purge-import-request")
      )
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("phone_number\n+251911123456\n"), filename: "contacts.csv", content_type: "text/csv"
      )
      import.file.attach(blob)
      old = 91.days.ago
      import.update_columns(updated_at: old)

      PurgeCampaignPayloadsJob.perform_now

      assert_operator import.reload.updated_at, :>, old
    end

    test "skips already-purged campaigns so later payloads are reached" do
      organization = organizations_organizations(:two)
      actor = core_users(:super_admin)
      old = 91.days.ago
      100.times do |index|
        campaign = Campaign.create!(
          organization:, created_by: actor, name: "Purged #{index} #{SecureRandom.hex(3)}", channel: "email",
          timezone: "Africa/Addis_Ababa", status: "completed", completed_at: old, updated_at: old
        )
        campaign.update_columns(message_body_ciphertext: nil, message_subject_ciphertext: nil)
      end
      target = Campaign.create!(
        organization:, created_by: actor, name: "Target #{SecureRandom.hex(3)}", channel: "email",
        timezone: "Africa/Addis_Ababa", status: "completed", completed_at: old, updated_at: old,
        message_body: "Reach this campaign"
      )

      PurgeCampaignPayloadsJob.perform_now

      assert_nil target.reload.message_body_ciphertext
    end

    private

    def build_delivery(status:)
      organization = organizations_organizations(:two)
      actor = core_users(:super_admin)
      account = CreditAccount.create!(organization:, channel: "email")
      rate = CreditRateVersion.create!(
        organization:, channel: "email", version: 1, currency: "ETB", unit_price_minor: 1,
        volume_tiers: [], effective_from: 1.hour.ago, status: "active",
        idempotency_key_digest: Digest::SHA256.hexdigest("reconcile-rate-#{SecureRandom.hex(4)}"),
        request_digest: Digest::SHA256.hexdigest("reconcile-request-#{SecureRandom.hex(4)}"), activated_at: 1.hour.ago
      )
      CreditLedgerEntry.create!(
        credit_account: account, entry_type: "top_up", quantity: 1, available_delta: 1,
        idempotency_key_digest: Digest::SHA256.hexdigest("reconcile-grant-#{SecureRandom.hex(4)}"), metadata: {}
      )
      campaign = Campaign.create!(
        organization:, created_by: actor, name: "Reconcile #{SecureRandom.hex(4)}", channel: "email",
        timezone: "Africa/Addis_Ababa", message_body: "Hello"
      )
      snapshot = CampaignAudienceSnapshot.create!(
        campaign:, source_spec: { "sources" => [] }, status: "ready", total_count: 1,
        processed_count: 1, eligible_quantity: 1, completed_at: Time.current
      )
      recipient = CampaignRecipient.create!(
        campaign:, audience_snapshot: snapshot, channel: "email", channel_address: "r@example.com",
        channel_address_digest: Digest::SHA256.hexdigest("reconcile-recipient"), source_type: "contact_list",
        eligibility_status: "eligible", quantity: 1
      )
      hold = Campaigns::CreditHolds::Reserve.call(
        account:, organization:, rate_version: rate, source_type: "Messaging::Campaign", source_id: campaign.id,
        quantity: 1, idempotency_key: "reconcile-hold-#{SecureRandom.hex(4)}"
      ).value
      delivery = CampaignDelivery.create!(
        campaign:, campaign_recipient: recipient, channel: "email", status:,
        claimed_at: status == "processing" ? Time.current : nil,
        idempotency_key_digest: Digest::SHA256.hexdigest("reconcile-delivery-#{SecureRandom.hex(4)}")
      )
      Campaigns::CreditHolds::Allocate.call(
        reservation: hold, delivery:, quantity: 1, idempotency_key: "reconcile-allocation-#{SecureRandom.hex(4)}"
      )
      [ campaign, delivery ]
    end
  end
end
