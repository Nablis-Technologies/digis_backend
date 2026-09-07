# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module Campaigns
    class CancelTest < ActiveSupport::TestCase
    include Core::AuditTestHelpers

    test "cancel releases a scheduled campaign hold before dispatch" do
        organization = organizations_organizations(:two)
        actor = core_users(:super_admin)
        campaign = Campaign.create!(
          organization:, created_by: actor, name: "Cancel #{SecureRandom.hex(4)}", channel: "email",
          timezone: "Africa/Addis_Ababa", send_at: 1.hour.from_now, message_body: "Hello"
        )
        account = CreditAccount.create!(organization:, channel: "email")
        rate = CreditRateVersion.create!(
          organization:, channel: "email", version: 1, currency: "ETB", unit_price_minor: 10,
          volume_tiers: [], effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("cancel-rate"),
          request_digest: Digest::SHA256.hexdigest("cancel-request"), activated_at: 1.hour.ago
        )
        CreditLedgerEntry.create!(
          credit_account: account, entry_type: "top_up", quantity: 5, available_delta: 5,
          idempotency_key_digest: Digest::SHA256.hexdigest("cancel-grant"), metadata: {}
        )
        snapshot = CampaignAudienceSnapshot.create!(
          campaign:, source_spec: { "sources" => [] }, status: "ready", total_count: 1,
          processed_count: 1, eligible_quantity: 1, completed_at: Time.current
        )
        CampaignRecipient.create!(
          campaign:, audience_snapshot: snapshot, channel: "email",
          channel_address: "cancel@example.com", channel_address_digest: Digest::SHA256.hexdigest("cancel-recipient"),
          source_type: "contact_list", eligibility_status: "eligible", quantity: 1
        )
        CampaignAttestation.create!(
          campaign:, audience_snapshot: snapshot, actor:, channel: "email", statement_version: 1,
          idempotency_key_digest: Digest::SHA256.hexdigest("cancel-attestation"),
          request_digest: Digest::SHA256.hexdigest("cancel-attestation-request"), attested_at: Time.current,
          metadata: {}
        )

        Estimate.call(campaign:, actor:, idempotency_key: "cancel-estimate")
        Launch.call(
          campaign:, actor:, idempotency_key: "cancel-launch", quote_digest: campaign.quote_digest,
          quoted_rate_version_id: campaign.quoted_rate_version_id, quoted_quantity: campaign.quoted_quantity
        )
        operation = -> { Cancel.call(campaign:, actor:, reason: "withdrawn", idempotency_key: "cancel-1") }
        assert_audit_idempotent(
          operation, action: "messaging.campaign.canceled", auditable_type: Campaign.name, auditable_id: campaign.id
        )
        result = operation.call

        assert result.success?, result.error&.message
        assert_equal "canceled", campaign.reload.status
        assert campaign.canceled_at
      assert_equal "campaign_canceled", CreditReservation.find_by!(source_id: campaign.id).resolution_code
      assert_audit_logged(action: "messaging.campaign.canceled", auditable: campaign, actor:)
    end

    test "validates a cancellation reason before accepting an already canceled campaign" do
      campaign = Campaign.create!(
        organization: organizations_organizations(:two), created_by: core_users(:super_admin),
        name: "Canceled reason #{SecureRandom.hex(4)}", channel: "email", timezone: "Africa/Addis_Ababa",
        status: "canceled", canceled_at: Time.current, message_body: "Hello"
      )

      result = Cancel.call(campaign:, actor: core_users(:super_admin), reason: "", idempotency_key: "cancel-blank")

      assert_equal "reason_required", result.error.code
    end

    test "does not cancel a campaign after scheduling has moved it to sending" do
      organization = organizations_organizations(:two)
      actor = core_users(:super_admin)
      campaign = Campaign.create!(
        organization:, created_by: actor, name: "Cancel race #{SecureRandom.hex(4)}", channel: "email",
        timezone: "Africa/Addis_Ababa", send_at: 1.minute.ago, message_body: "Hello", status: "scheduled"
      )
      stale_campaign = Campaign.find(campaign.id)

      ProcessScheduledCampaignsJob.perform_now
      result = Cancel.call(campaign: stale_campaign, actor:, reason: "withdrawn", idempotency_key: "cancel-race")

      assert_equal "campaign_invalid_state", result.error.code
      assert_equal "sending", campaign.reload.status
    end
    end
  end
end
