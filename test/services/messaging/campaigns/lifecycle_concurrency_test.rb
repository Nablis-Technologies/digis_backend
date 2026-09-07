# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module Campaigns
    class LifecycleConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @actor = core_users(:super_admin)
        @organization = Organizations::Organization.create!(
          name: "Concurrent campaign #{SecureRandom.hex(6)}", organizer_type: "company", category: "music"
        )
        Organizations::Membership.create!(user: @actor, organization: @organization, role: "owner", status: "active")
        @account = CreditAccount.create!(organization: @organization, channel: "sms")
        @rate = CreditRateVersion.create!(
          organization: @organization, channel: "sms", version: 100, currency: "ETB", unit_price_minor: 1,
          volume_tiers: [], effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("concurrent-campaign-rate"),
          request_digest: Digest::SHA256.hexdigest("concurrent-campaign-rate-request"), activated_at: 1.hour.ago
        )
        CreditLedgerEntry.create!(
          credit_account: @account, entry_type: "top_up", quantity: 10, available_delta: 10,
          idempotency_key_digest: Digest::SHA256.hexdigest("concurrent-campaign-grant"), metadata: {}
        )
        @campaign = Campaign.create!(
          organization: @organization, created_by: @actor,
          name: "Concurrent launch #{SecureRandom.hex(4)}", channel: "sms", timezone: "Africa/Addis_Ababa",
          message_body: "Hello", metadata: { "currency" => "ETB" }
        )
        @snapshot = CampaignAudienceSnapshot.create!(
          campaign: @campaign, source_spec: { "sources" => [] }, status: "ready",
          total_count: 1, processed_count: 1, eligible_quantity: 1, completed_at: Time.current
        )
        CampaignRecipient.create!(
          campaign: @campaign, audience_snapshot: @snapshot, channel: "sms",
          channel_address: "+251911123456", channel_address_digest: Digest::SHA256.hexdigest("concurrent-recipient"),
          source_type: "contact_list", eligibility_status: "eligible", quantity: 1
        )
        CampaignAttestation.create!(
          campaign: @campaign, audience_snapshot: @snapshot, actor: @actor, channel: "sms", statement_version: 1,
          idempotency_key_digest: Digest::SHA256.hexdigest("concurrent-attestation"),
          request_digest: Digest::SHA256.hexdigest("concurrent-attestation-request"), attested_at: Time.current,
          metadata: {}
        )
        assert Estimate.call(campaign: @campaign, actor: @actor, idempotency_key: "concurrent-estimate").success?
        @quote = {
          quote_digest: @campaign.reload.quote_digest,
          quoted_rate_version_id: @campaign.quoted_rate_version_id,
          quoted_quantity: @campaign.quoted_quantity
        }
      end

      teardown do
        Campaign.where(id: @campaign.id).delete_all
        CreditReservation.where(credit_account_id: @account.id).delete_all
        connection = Messaging::ApplicationRecord.connection
        connection.execute(
          "ALTER TABLE messaging_credit_ledger_entries DISABLE TRIGGER trg_messaging_credit_ledger_entry_immutable"
        )
        CreditLedgerEntry.where(credit_account_id: @account.id).delete_all
        CreditAccount.where(id: @account.id).delete_all
        CreditRateVersion.where(id: @rate.id).delete_all
        Organizations::Membership.where(organization_id: @organization.id).delete_all
        Organizations::Organization.where(id: @organization.id).delete_all
      ensure
        connection&.execute(
          "ALTER TABLE messaging_credit_ledger_entries ENABLE TRIGGER trg_messaging_credit_ledger_entry_immutable"
        )
      end

      test "concurrent launches share one hold, launch event, and audit" do
        results = Prosopite.pause do
          race = run_database_race do
            Launch.call(
              campaign: Campaign.find(@campaign.id), actor: Core::User.find(@actor.id),
              idempotency_key: "concurrent-launch", **@quote
            )
          end
          assert_empty race.errors, race.errors.inspect
          race.results
        end

        assert_equal 2, results.count(&:success?)
        assert_equal 1, CreditReservation.where(source_type: "Messaging::Campaign", source_id: @campaign.id).count
        assert_equal 1, Core::OutboxEvent.where(event_type: "messaging.campaign.launched", aggregate_id: @campaign.id).count
        assert_equal 1, Core::AuditLog.where(
          audit_key: "messaging-campaign-launch-#{@campaign.id}-#{Core::IdempotencyKey.new("concurrent-launch").digest}"
        ).count
        assert_operator @account.reload.ledger_entries.sum(:available_delta), :>=, 0
      end
    end
  end
end
