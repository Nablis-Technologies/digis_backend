# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module Campaigns
    class DeliverTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:two)
        @actor = core_users(:super_admin)
        @account = CreditAccount.create!(organization: @organization, channel: "sms")
        @rate = CreditRateVersion.create!(
          organization: @organization, channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
          volume_tiers: [], effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("deliver-rate"),
          request_digest: Digest::SHA256.hexdigest("deliver-rate-request"), activated_at: 1.hour.ago
        )
        CreditLedgerEntry.create!(
          credit_account: @account, entry_type: "top_up", quantity: 10, available_delta: 10,
          idempotency_key_digest: Digest::SHA256.hexdigest("deliver-grant"), metadata: {}
        )
        @campaign = Campaign.create!(
          organization: @organization, created_by: @actor, name: "Deliver #{SecureRandom.hex(4)}",
          channel: "sms", timezone: "Africa/Addis_Ababa", message_body: "Hello"
        )
        @snapshot = CampaignAudienceSnapshot.create!(
          campaign: @campaign, source_spec: { "sources" => [] }, status: "ready",
          total_count: 1, processed_count: 1, eligible_quantity: 1, completed_at: Time.current
        )
        @recipient = CampaignRecipient.create!(
          campaign: @campaign, audience_snapshot: @snapshot, channel: "sms",
          channel_address: "+251911123456", channel_address_digest: Digest::SHA256.hexdigest("deliver-recipient"),
          source_type: "contact_list", eligibility_status: "eligible", quantity: 1
        )
        @hold = CreditHolds::Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::Campaign", source_id: @campaign.id, quantity: 1,
          idempotency_key: "deliver-hold"
        ).value
        @delivery = CampaignDelivery.create!(
          campaign: @campaign, campaign_recipient: @recipient, channel: "sms", status: "pending",
          idempotency_key_digest: Digest::SHA256.hexdigest("deliver-delivery")
        )
        CreditHolds::Allocate.call(
          reservation: @hold, delivery: @delivery, quantity: 1, idempotency_key: "deliver-allocation"
        )
      end

      test "settles a successful provider delivery" do
        adapter = Messaging::Providers::TestAdapter.new(default: :delivered, provider: "fake")
        Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)

        result = Deliver.call(delivery_id: @delivery.id)

        assert result.success?, result.error&.message
        assert_equal "delivered", @delivery.reload.status
        assert_equal "consumed", @delivery.credit_allocation.reload.status
      end

      test "settles a delivery through the preview provider configuration" do
        previous_registry = Rails.application.config.x.messaging_provider_registry
        registry = Messaging::Providers::Registry.new
        Messaging::Providers::PreviewConfiguration.call(
          env: { "RENDER_PREVIEW" => "true", "DIGIS_MESSAGING_PREVIEW_PROVIDER" => "true" }, registry:
        )
        Rails.application.config.x.messaging_provider_registry = registry

        result = Deliver.call(delivery_id: @delivery.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal "delivered", @delivery.reload.status
        assert_equal "preview", @delivery.provider
        assert_equal "consumed", @delivery.credit_allocation.reload.status
      ensure
        Rails.application.config.x.messaging_provider_registry = previous_registry
      end

      test "preloads the direct allocation when claiming by delivery id" do
        claimed = Deliver.new(delivery_id: @delivery.id).send(:claim_delivery)

        assert_predicate claimed.association(:credit_allocation), :loaded?
        assert_equal @delivery.credit_allocation.id, claimed.credit_allocation.id
      end

      test "does not settle credits when the delivery claim is lost before finalization" do
        @delivery.update_columns(status: "processing", claimed_at: Time.current, attempts: 1)
        service_class = Class.new(Deliver) do
          define_method(:update_claimed) do |_delivery, **_attributes|
            raise Messaging::Campaigns::Deliver::ClaimLost
          end
        end

        assert_raises(Deliver::ClaimLost) do
          service_class.new(delivery: @delivery).send(
            :finalize_outcome, @delivery, :delivered, "delivered", status: "delivered"
          )
        end

        assert_equal "allocated", @delivery.credit_allocation.reload.status
        assert_empty @account.reload.ledger_entries.where(entry_type: "consume")
      end

      test "does not refund credits when the max-attempt claim is lost before finalization" do
        @delivery.update_columns(status: "processing", claimed_at: Time.current, attempts: Deliver::MAX_ATTEMPTS)
        service_class = Class.new(Deliver) do
          define_method(:update_claimed) do |_delivery, **_attributes|
            raise Messaging::Campaigns::Deliver::ClaimLost
          end
        end

        assert_raises(Deliver::ClaimLost) do
          service_class.new(delivery: @delivery).send(
            :release_for_retry, @delivery, RuntimeError.new("provider timeout")
          )
        end

        assert_equal "allocated", @delivery.credit_allocation.reload.status
        assert_empty @account.reload.ledger_entries.where(entry_type: "refund")
      end

      test "releases a consent-suppressed delivery without provider I/O" do
        @recipient.update!(eligibility_status: "suppressed", eligibility_reason: "global_suppression")

        result = Deliver.call(delivery_id: @delivery.id)

        assert result.success?, result.error&.message
        assert_equal "suppressed", @delivery.reload.status
        assert_equal "released", @delivery.credit_allocation.reload.status
      end

      test "returns the claimed delivery in the batched outcome" do
        adapter = Messaging::Providers::TestAdapter.new(default: :delivered, provider: "fake")
        Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)

        result = Deliver.call(delivery: @delivery, settle: false)

        assert result.success?, result.error&.message
        assert_equal @delivery.id, result.value.delivery.id
        assert_equal @delivery.id, result.value.allocation.delivery_id
      end

      test "renders campaign variables before sending to the provider" do
        @campaign.update!(message_body: "Hello {{ first_name }} from {{ organization_name }}")
        @recipient.update!(first_name: "Aster")
        captured = []
        adapter = Class.new(Messaging::Providers::Adapter) do
          define_method(:initialize) { |messages| @messages = messages }

          define_method(:deliver_campaign) do |content:, **|
            @messages << content
            Messaging::Providers::DeliveryResult.delivered(provider: "fake")
          end
        end.new(captured)
        Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)

        result = Deliver.call(delivery_id: @delivery.id)

        assert result.success?, result.error&.message
        assert_equal "Hello Aster from #{@organization.name}", captured.fetch(0).fetch(:body)
        assert_no_match Messaging::Campaigns::Templates::Variables::TOKEN, captured.fetch(0).fetch(:body)
      end

      test "stops retrying a delivery after the maximum attempts" do
        @delivery.update_columns(attempts: 4)
        adapter = Messaging::Providers::TestAdapter.new(default: :retryable, provider: "fake")
        Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)

        result = Deliver.call(delivery_id: @delivery.id)

        assert result.success?, result.error&.message
        delivery = @delivery.reload
        assert_equal "failed", delivery.status
        assert_equal "max_attempts_exceeded", delivery.failure_code
        assert_equal "refunded", delivery.credit_allocation.reload.status
      end

      test "returns a failed batched outcome when provider errors exhaust attempts" do
        @delivery.update_columns(attempts: 4)
        adapter = Messaging::Providers::TestAdapter.new(default: :raise, provider: "fake")
        Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)

        result = Deliver.call(delivery: @delivery, settle: false)

        assert result.success?, result.error&.message
        delivery = @delivery.reload
        assert_equal "failed", delivery.status
        assert_equal "max_attempts_exceeded", delivery.failure_code
        settlement = CreditHolds::SettleBatch.call(outcomes: [ result.value ])
        assert settlement.success?, settlement.error&.message
        assert_equal "refunded", delivery.credit_allocation.reload.status
      end

      test "returns a retryable batched outcome when a provider error is recoverable" do
        adapter = Messaging::Providers::TestAdapter.new(default: :raise, provider: "fake")
        Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)

        result = Deliver.call(delivery: @delivery, settle: false)

        assert result.success?, result.error&.message
        assert_instance_of Deliver::DeliveryOutcome, result.value
        assert_equal :retryable, result.value.outcome
        assert_equal "pending", @delivery.reload.status
        assert_equal "allocated", @delivery.credit_allocation.reload.status
      end

      test "returns success after settling a provider error at the attempt limit" do
        @delivery.update_columns(attempts: 4)
        adapter = Messaging::Providers::TestAdapter.new(default: :raise, provider: "fake")
        Rails.application.config.x.messaging_provider_registry.register(channel: "sms", adapter:)

        result = Deliver.call(delivery_id: @delivery.id)

        assert result.success?, result.error&.message
        assert_equal "failed", @delivery.reload.status
        assert_equal "max_attempts_exceeded", @delivery.failure_code
        assert_equal "refunded", @delivery.credit_allocation.reload.status
      end
    end
  end
end
