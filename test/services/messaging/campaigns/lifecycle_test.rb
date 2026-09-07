# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module Campaigns
    class LifecycleTest < ActiveSupport::TestCase
      include Core::AuditTestHelpers

    setup do
        @organization = organizations_organizations(:two)
        @actor = core_users(:super_admin)
        @account = CreditAccount.create!(organization: @organization, channel: "sms")
        @rate = CreditRateVersion.create!(
          organization: @organization, channel: "sms", version: 1, currency: "ETB", unit_price_minor: 50,
          volume_tiers: [], effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("lifecycle-rate"),
          request_digest: Digest::SHA256.hexdigest("lifecycle-rate-request"), activated_at: 1.hour.ago
        )
        CreditLedgerEntry.create!(
          credit_account: @account, entry_type: "top_up", quantity: 100, available_delta: 100,
          idempotency_key_digest: Digest::SHA256.hexdigest("lifecycle-grant"), metadata: {}
        )
        @campaign = Campaign.create!(
          organization: @organization, created_by: @actor,
          name: "Lifecycle #{SecureRandom.hex(4)}", channel: "sms", timezone: "Africa/Addis_Ababa",
          message_body: "ሰ" * 71
        )
        @snapshot = CampaignAudienceSnapshot.create!(
          campaign: @campaign, source_spec: { "sources" => [] }, status: "ready",
          total_count: 1, processed_count: 1, eligible_quantity: 2, completed_at: Time.current
        )
        create_recipient(quantity: 2)
        CampaignAttestation.create!(
          campaign: @campaign, audience_snapshot: @snapshot, actor: @actor, channel: "sms",
          statement_version: 1, idempotency_key_digest: Digest::SHA256.hexdigest("attestation"),
          request_digest: Digest::SHA256.hexdigest("attestation-request"), attested_at: Time.current,
          metadata: {}
        )
      end

      test "creates an organization-scoped draft with a fixed channel and replays its key" do
        result = Create.call(
          organization: @organization, actor: @actor, name: "Created #{SecureRandom.hex(4)}",
          channel: "email", timezone: "Africa/Addis_Ababa", idempotency_key: "create-campaign-1"
        )

        assert result.success?, result.error&.message
        assert_equal "draft", result.value.status
        assert_equal "email", result.value.channel
      end

      test "persists campaign variables through creation" do
        result = Create.call(
          organization: @organization, actor: @actor, name: "Variables #{SecureRandom.hex(4)}",
          channel: "email", timezone: "Africa/Addis_Ababa", variables: { ticket_link: "https://digis.et/tickets" },
          idempotency_key: "create-campaign-variables"
        )

        assert result.success?, result.error&.message
        assert_equal "https://digis.et/tickets", result.value.reload.variables.fetch("ticket_link")
      end

      test "only updates campaign composition while it is draft" do
        result = Update.call(
          campaign: @campaign, actor: @actor,
          attributes: { name: "Updated campaign", message_body: "Updated" },
          idempotency_key: "update-campaign-1"
        )
        assert result.success?, result.error&.message
        assert_equal "Updated campaign", @campaign.reload.name

        @campaign.update_columns(status: "sending")
        blocked = Update.call(
          campaign: @campaign, actor: @actor, attributes: { name: "Nope" },
          idempotency_key: "update-campaign-2"
        )
        assert_equal "campaign_invalid_state", blocked.error.code
      end

      test "returns a typed failure when updating to an existing campaign name" do
        existing = Campaign.create!(
          organization: @organization, created_by: @actor, name: "Existing campaign #{SecureRandom.hex(4)}",
          channel: "sms", timezone: "Africa/Addis_Ababa", message_body: "Hello"
        )

        result = Update.call(
          campaign: @campaign, actor: @actor, attributes: { name: existing.name },
          idempotency_key: "update-duplicate-name"
        )

        assert_equal "campaign_name_taken", result.error.code
        assert_equal @campaign.id, @campaign.reload.id
      end

      test "estimate uses the stored segment quantity and pins the selected rate" do
        result = Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-1")

        assert result.success?, result.error&.message
        assert_equal "ready", result.value.fetch(:status)
        assert_equal 2, result.value.fetch(:quantity)
        assert_equal @rate.id, @campaign.reload.quoted_rate_version_id
        assert_equal 15.minutes, @campaign.quote_expires_at - @campaign.quoted_at
      end

      test "estimate replay preserves the tier price and rejects an expired quote" do
        @rate.update_columns(status: "retired", retired_at: Time.current)
        tiered_rate = CreditRateVersion.create!(
          organization: @organization, channel: "sms", version: 2, currency: "ETB", unit_price_minor: 50,
          volume_tiers: [ { "from" => 1, "to" => 100, "unit_price_minor" => 25 } ],
          effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("tiered-lifecycle-rate"),
          request_digest: Digest::SHA256.hexdigest("tiered-lifecycle-rate-request"), activated_at: 1.hour.ago
        )

        first = Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-tiered-replay")
        replay = Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-tiered-replay")

        assert_equal 25, first.value.fetch(:unit_price_minor)
        assert_equal tiered_rate.id, @campaign.reload.quoted_rate_version_id
        assert_equal 25, replay.value.fetch(:unit_price_minor)

        @campaign.update_columns(quoted_at: 16.minutes.ago, quote_expires_at: 1.minute.ago)
        expired = Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-tiered-replay")

        assert_equal "campaign_quote_stale", expired.error.code
      end

      test "estimate starts audience preparation when the campaign has no snapshot" do
        campaign = Campaign.create!(
          organization: @organization, created_by: @actor,
          name: "Prepare on estimate #{SecureRandom.hex(4)}", channel: "sms",
          timezone: "Africa/Addis_Ababa", message_body: "Hello",
          metadata: { "audience_sources" => [] }
        )

        result = Estimate.call(campaign:, actor: @actor, idempotency_key: "estimate-prepare")

        assert result.success?
        assert_equal "preparing", result.value.fetch(:status)
        assert campaign.reload.audience_snapshot
      end

      test "estimate reports an empty eligible audience before resolving a rate" do
        campaign = Campaign.create!(
          organization: @organization, created_by: @actor,
          name: "Empty audience #{SecureRandom.hex(4)}", channel: "sms",
          timezone: "Africa/Addis_Ababa", message_body: "Hello"
        )
        CampaignAudienceSnapshot.create!(
          campaign:, source_spec: { "sources" => [] }, status: "ready", total_count: 0,
          processed_count: 0, eligible_quantity: 0, completed_at: Time.current
        )

        result = Estimate.call(campaign:, actor: @actor, idempotency_key: "estimate-empty-audience")

        assert_equal "campaign_audience_empty", result.error.code
        assert_nil campaign.reload.quoted_quantity
      end

      test "draft message edits invalidate the stored quote" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-update-message")

        result = Update.call(
          campaign: @campaign, actor: @actor,
          attributes: { message_body: "ሰ" * 140 }, idempotency_key: "update-message-quote"
        )

        assert result.success?, result.error&.message
        campaign = @campaign.reload
        assert_nil campaign.quoted_quantity
        assert_nil campaign.quoted_rate_version_id
        assert_nil campaign.quote_digest
        assert_nil campaign.quoted_at
        assert_nil campaign.quote_expires_at
      end

      test "draft variable edits invalidate the stored quote" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-update-variables")

        result = Update.call(
          campaign: @campaign, actor: @actor,
          attributes: { variables: { ticket_link: "https://digis.et/tickets" } },
          idempotency_key: "update-variables-quote"
        )

        assert result.success?, result.error&.message
        campaign = @campaign.reload
        assert_equal "https://digis.et/tickets", campaign.variables.fetch("ticket_link")
        assert_nil campaign.quoted_quantity
        assert_nil campaign.quote_digest
      end

      test "draft audience edits invalidate the quote and snapshot" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-update-audience")

        result = Update.call(
          campaign: @campaign, actor: @actor,
          attributes: { metadata: { "audience_sources" => [] } }, idempotency_key: "update-audience-quote"
        )

        assert result.success?, result.error&.message
        campaign = @campaign.reload
        assert_nil campaign.audience_snapshot
        assert_nil campaign.quoted_quantity
        assert_nil campaign.quote_digest
      end

      test "launch creates one aggregate hold and one durable launch event" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-launch")

        result = launch_with_quote("launch-1")

        assert result.success?, result.error&.message
        assert_equal "sending", @campaign.reload.status
        assert_equal 1, CreditReservation.where(source_type: "Messaging::Campaign", source_id: @campaign.id).count
        event = Core::OutboxEvent.find_by!(event_type: "messaging.campaign.launched")
        assert_equal @campaign.id, event.payload.fetch("campaign_id")
        assert_equal @campaign.launch_version, event.payload.fetch("launch_version")
      end

      test "launch replays the same key but rejects a different key" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-replay")
        operation = -> { launch_with_quote("launch-replay") }
        assert_audit_idempotent(
          operation, action: "messaging.campaign.launched", auditable_type: Campaign.name,
          auditable_id: @campaign.id
        )
        conflict = launch_with_quote("launch-other")

        assert_equal "idempotency_conflict", conflict.error.code
        assert_equal 1, CreditReservation.where(source_id: @campaign.id).count
      end

      test "launch rejects a mismatched quote without reserving credits" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-stale")

        result = Launch.call(
          campaign: @campaign, actor: @actor, idempotency_key: "launch-stale",
          quote_digest: "0" * 64, quoted_rate_version_id: @campaign.quoted_rate_version_id,
          quoted_quantity: @campaign.quoted_quantity
        )

        assert_equal "campaign_quote_stale", result.error.code
        assert_not CreditReservation.exists?(source_id: @campaign.id)
      end

      test "launch requires every quoted identity field" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-required-quote")

        result = Launch.call(campaign: @campaign, actor: @actor, idempotency_key: "launch-missing-quote")

        assert_equal "campaign_quote_stale", result.error.code
        assert_not CreditReservation.exists?(source_id: @campaign.id)
      end

      test "launch replay requires the same quoted identity" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-replay-quote")
        launch_with_quote("launch-replay-quote")

        result = Launch.call(campaign: @campaign, actor: @actor, idempotency_key: "launch-replay-quote")

        assert_equal "campaign_quote_stale", result.error.code
      end

      test "launch replays the same request after the quote window expires" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-expired-launch")
        launch_with_quote("launch-expired-replay")
        campaign = @campaign.reload
        campaign.update_columns(quoted_at: 2.hours.ago, quote_expires_at: 1.hour.ago)

        result = Launch.call(
          campaign:, actor: @actor, idempotency_key: "launch-expired-replay",
          quote_digest: campaign.quote_digest, quoted_rate_version_id: campaign.quoted_rate_version_id,
          quoted_quantity: campaign.quoted_quantity
        )

        assert result.success?, result.error&.message
        assert_equal "sending", result.value.status
      end

      test "launch replays successfully after the campaign reaches a terminal state" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-terminal-launch")
        launch_with_quote("launch-terminal-replay")
        @campaign.update_columns(status: "completed", completed_at: Time.current)

        result = launch_with_quote("launch-terminal-replay")

        assert result.success?, result.error&.message
        assert_equal "completed", result.value.status
      end

      test "launch rejects a snapshot that is not ready" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-snapshot-state")
        @snapshot.update_columns(status: "preparing")

        result = launch_with_quote("launch-snapshot-state")

        assert_equal "campaign_audience_snapshot_invalid", result.error.code
        assert_not CreditReservation.exists?(source_id: @campaign.id)
      end

      test "estimate rejects an audience above the active daily quota" do
        CampaignVolumePolicy.create!(
          organization: @organization, channel: "sms", timezone: "Africa/Addis_Ababa",
          daily_limit: 1, monthly_limit: 10, active: true, updated_by: @actor,
          idempotency_key_digest: Digest::SHA256.hexdigest("quota"),
          request_digest: Digest::SHA256.hexdigest("quota-request")
        )

        result = Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-quota")

        assert_equal "campaign_quota_exceeded", result.error.code
      end

      test "quota ignores an estimated draft that was canceled before launch" do
        CampaignVolumePolicy.create!(
          organization: @organization, channel: "sms", timezone: "Africa/Addis_Ababa",
          daily_limit: 2, monthly_limit: 10, active: true, updated_by: @actor,
          idempotency_key_digest: Digest::SHA256.hexdigest("quota-canceled-draft"),
          request_digest: Digest::SHA256.hexdigest("quota-canceled-draft-request")
        )
        campaign = Campaign.create!(
          organization: @organization, created_by: @actor, name: "Canceled draft #{SecureRandom.hex(4)}",
          channel: "sms", timezone: "Africa/Addis_Ababa", status: "canceled", canceled_at: Time.current,
          message_body: "Hello", quoted_rate_version: @rate, quoted_quantity: 2, quoted_unit_price_minor: 50,
          quote_digest: Digest::SHA256.hexdigest("canceled-draft-quote"), quoted_at: Time.current,
          quote_expires_at: 15.minutes.from_now
        )

        result = Quota.call(
          organization: @organization, channel: "sms", quantity: 2, timezone: "Africa/Addis_Ababa"
        )

        assert result.success?, result.error&.message
        assert_nil campaign.reload.launched_at
      end

      test "quota counts a launch in its launch-time window" do
        launch_at = Time.current.change(hour: 0, min: 5, sec: 0)
        CampaignVolumePolicy.create!(
          organization: @organization, channel: "sms", timezone: "Africa/Addis_Ababa",
          daily_limit: 2, monthly_limit: 100, active: true, updated_by: @actor,
          idempotency_key_digest: Digest::SHA256.hexdigest("quota-launch-window"),
          request_digest: Digest::SHA256.hexdigest("quota-launch-window-request")
        )
        Campaign.create!(
          organization: @organization, created_by: @actor, name: "Prior launch #{SecureRandom.hex(4)}",
          channel: "sms", timezone: "Africa/Addis_Ababa", status: "canceled", canceled_at: launch_at,
          launched_at: launch_at, message_body: "Hello", quoted_rate_version: @rate, quoted_quantity: 2,
          quoted_unit_price_minor: 50, quote_digest: Digest::SHA256.hexdigest("prior-launch-quote"),
          quoted_at: launch_at - 1.day, quote_expires_at: launch_at + 15.minutes
        )

        result = Quota.call(
          organization: @organization, channel: "sms", quantity: 1,
          timezone: "Africa/Addis_Ababa", at: launch_at
        )

        assert_equal "campaign_quota_exceeded", result.error&.code, result.inspect
      end

      test "attestation requires a ready audience snapshot" do
        @snapshot.update_columns(status: "preparing")

        result = Attest.call(
          campaign: @campaign, audience_snapshot: @snapshot, actor: @actor,
          channel: "sms", confirmation: true, historical_basis: "issued", idempotency_key: "attest-preparing"
        )

        assert_equal "campaign_audience_invalid", result.error.code
      end

      test "validates an abort reason before accepting an already canceled campaign" do
        campaign = Campaign.create!(
          organization: @organization, created_by: @actor,
          name: "Canceled abort reason #{SecureRandom.hex(4)}", channel: "sms",
          timezone: "Africa/Addis_Ababa", status: "canceled", canceled_at: Time.current,
          message_body: "Hello"
        )

        result = Abort.call(campaign:, actor: @actor, reason: "", idempotency_key: "abort-blank")

        assert_equal "reason_required", result.error.code
      end

      test "abort releases only the unallocated hold remainder" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-abort")
        launch_with_quote("launch-abort")
        delivery = CampaignDelivery.create!(
          campaign: @campaign, campaign_recipient: @campaign.recipients.first, channel: "sms", status: "pending",
          idempotency_key_digest: Digest::SHA256.hexdigest("abort-delivery")
        )
        hold = CreditReservation.find_by!(source_id: @campaign.id)
        allocation = CreditHolds::Allocate.call(
          reservation: hold, delivery:, quantity: 1, idempotency_key: "abort-allocation"
        ).value
        CreditHolds::Settle.call(allocation:, outcome: :delivered, idempotency_key: "abort-settle")
        @campaign.update_columns(status: "sending")

        operation = -> {
          Abort.call(campaign: @campaign, actor: @actor, reason: "wrong_date", idempotency_key: "abort-1")
        }
        assert_audit_idempotent(
          operation, action: "messaging.campaign.aborted", auditable_type: Campaign.name, auditable_id: @campaign.id
        )
        result = operation.call

        assert result.success?, result.error&.message
        assert_equal "canceled", @campaign.reload.status
        assert @campaign.canceled_at
        assert_equal "campaign_aborted", hold.reload.resolution_code
        assert_equal 1, @account.reload.ledger_entries.where(entry_type: "release").sum(:quantity)
        assert_audit_logged(action: "messaging.campaign.aborted", auditable: @campaign, actor: @actor)
      end

      test "aborts a sending campaign while an allocated delivery is in flight" do
        Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "estimate-abort-in-flight")
        launch_with_quote("launch-abort-in-flight")
        delivery = CampaignDelivery.create!(
          campaign: @campaign, campaign_recipient: @campaign.recipients.first, channel: "sms", status: "pending",
          idempotency_key_digest: Digest::SHA256.hexdigest("abort-in-flight-delivery")
        )
        hold = CreditReservation.find_by!(source_id: @campaign.id)
        CreditHolds::Allocate.call(
          reservation: hold, delivery:, quantity: 1, idempotency_key: "abort-in-flight-allocation"
        )
        @campaign.reload

        result = Abort.call(
          campaign: @campaign, actor: @actor, reason: "wrong_date", idempotency_key: "abort-in-flight"
        )

        assert result.success?, result.error&.message
        assert_equal "canceled", @campaign.reload.status
        assert_equal "reserved", hold.reload.status
        assert_equal "pending", delivery.reload.status
      end

      private

      def create_recipient(quantity:)
        CampaignRecipient.create!(
          campaign: @campaign, audience_snapshot: @snapshot, channel: "sms",
          channel_address: "+251911123456", channel_address_digest: Digest::SHA256.hexdigest("recipient"),
          source_type: "contact_list", eligibility_status: "eligible", quantity:
        )
      end

      def launch_with_quote(idempotency_key)
        Launch.call(
          campaign: @campaign, actor: @actor, idempotency_key:,
          quote_digest: @campaign.quote_digest,
          quoted_rate_version_id: @campaign.quoted_rate_version_id,
          quoted_quantity: @campaign.quoted_quantity
        )
      end
    end
  end
end
