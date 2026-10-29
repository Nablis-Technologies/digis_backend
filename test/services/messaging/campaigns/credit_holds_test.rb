# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module Campaigns
    class CreditHoldsTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:two)
        @actor = core_users(:super_admin)
        @account = CreditAccount.create!(organization: @organization, channel: "sms")
        @rate = CreditRateVersion.create!(
          organization: @organization, channel: "sms", version: 1, currency: "ETB", unit_price_minor: 50,
          volume_tiers: [], effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("campaign-rate"),
          request_digest: Digest::SHA256.hexdigest("campaign-rate-request"), activated_at: 1.hour.ago
        )
        CreditLedgerEntry.create!(
          credit_account: @account, entry_type: "top_up", quantity: 100, available_delta: 100,
          idempotency_key_digest: Digest::SHA256.hexdigest("campaign-grant"), metadata: {}
        )
        @campaign = Campaign.create!(
          organization: @organization, created_by: @actor,
          name: "Hold #{SecureRandom.hex(4)}", channel: "sms", timezone: "Africa/Addis_Ababa",
          message_body: "Hello"
        )
      end

      test "creates one aggregate campaign hold and replays the same key" do
        operation = -> {
          CreditHolds::Reserve.call(
            account: @account, organization: @organization, rate_version: @rate,
            source_type: "Messaging::Campaign", source_id: @campaign.id, quantity: 10,
            idempotency_key: "campaign-hold-1"
          )
        }

        assert_idempotent(operation, counter: -> { CreditReservation.count })
        hold = operation.call.value
        assert_equal "Messaging::Campaign", hold.source_type
        assert_equal(-10, @account.reload.ledger_entries.where(entry_type: "reserve").sum(:available_delta))
      end

      test "returns success for an empty allocation batch without issuing insert SQL" do
        hold = reserve_hold(quantity: 1)
        original_insert_all = CampaignCreditAllocation.method(:insert_all)
        CampaignCreditAllocation.define_singleton_method(:insert_all) do |*_args, **_options|
          raise "empty batches must not call insert_all"
        end

        begin
          result = CreditHolds::AllocateBatch.call(reservation: hold, deliveries: [])
        ensure
          CampaignCreditAllocation.define_singleton_method(:insert_all, original_insert_all)
        end

        assert result.success?, result.error&.message
        assert_equal 0, CampaignCreditAllocation.where(credit_reservation_id: hold.id).count
      end

      test "allocates and settles delivery slices before releasing the unallocated remainder" do
        hold = reserve_hold(quantity: 10)
        first = create_delivery("first")
        second = create_delivery("second")

        first_allocation = CreditHolds::Allocate.call(
          reservation: hold, delivery: first, quantity: 3, idempotency_key: "allocate-first"
        ).value
        second_allocation = CreditHolds::Allocate.call(
          reservation: hold, delivery: second, quantity: 2, idempotency_key: "allocate-second"
        ).value
        CreditHolds::Settle.call(
          allocation: first_allocation, outcome: :delivered, idempotency_key: "settle-first"
        )
        CreditHolds::Settle.call(
          allocation: second_allocation, outcome: :suppressed, idempotency_key: "settle-second"
        )

        result = CreditHolds::Finalize.call(
          reservation: hold
        )

        assert result.success?
        assert_equal "released", result.value.status
        assert_equal %w[consumed released], hold.reload.allocations.order(:created_at).map(&:status)
        assert_equal 3, @account.reload.ledger_entries.where(entry_type: "consume").sum(:quantity)
        assert_equal 7, @account.ledger_entries.where(entry_type: "release").sum(:quantity)
      end

      test "finalizes a hold without a caller idempotency key" do
        hold = reserve_hold(quantity: 1)

        result = CreditHolds::Finalize.call(reservation: hold)

        assert result.success?, result.error&.message
        assert_equal "released", result.value.status
      end

      test "batch settlement rejects a terminal allocation with a conflicting outcome" do
        hold = reserve_hold(quantity: 2)
        delivery = create_delivery("batch-conflict")
        allocation = CreditHolds::Allocate.call(
          reservation: hold, delivery:, quantity: 2, idempotency_key: "batch-conflict-allocation"
        ).value
        CreditHolds::Settle.call(
          allocation:, outcome: :delivered, idempotency_key: "batch-conflict-delivered"
        )
        outcome = Messaging::Campaigns::Deliver::DeliveryOutcome.new(
          delivery:, allocation:, outcome: :suppressed, reason: "suppressed"
        )

        result = CreditHolds::SettleBatch.call(outcomes: [ outcome ])

        assert_equal "credit_idempotency_conflict", result.error.code
        assert_equal "consumed", allocation.reload.status
      end

      test "singular and batch allocation paths share one canonical identity" do
        hold = reserve_hold(quantity: 1)
        delivery = create_delivery("allocation-identity")
        allocation = CreditHolds::Allocate.call(
          reservation: hold, delivery:, quantity: 1, idempotency_key: "singular-allocation"
        ).value

        result = CreditHolds::AllocateBatch.call(reservation: hold, deliveries: [ delivery ])

        assert result.success?, result.error&.message
        assert_equal allocation.reload.idempotency_key_digest, CreditHolds::AllocationIdentity.digest(
          reservation: hold, delivery:, quantity: 1
        )
      end

      test "singular and batch settlement share one ledger identity" do
        hold = reserve_hold(quantity: 1)
        delivery = create_delivery("settlement-identity")
        allocation = CreditHolds::Allocate.call(
          reservation: hold, delivery:, quantity: 1, idempotency_key: "settlement-allocation"
        ).value
        CreditHolds::Settle.call(
          allocation:, outcome: :delivered, idempotency_key: "settlement-singular"
        )
        outcome = Messaging::Campaigns::Deliver::DeliveryOutcome.new(
          delivery:, allocation:, outcome: :delivered, reason: "delivered"
        )

        result = CreditHolds::SettleBatch.call(outcomes: [ outcome ])

        assert result.success?, result.error&.message
        assert_equal 1, @account.reload.ledger_entries.where(
          reference_type: "Messaging::CampaignDelivery", reference_id: delivery.id, entry_type: "consume"
        ).count
      end

      private

      def reserve_hold(quantity:)
        CreditHolds::Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::Campaign", source_id: @campaign.id, quantity:,
          idempotency_key: "hold-#{SecureRandom.hex(4)}"
        ).value
      end

      def create_delivery(suffix)
        snapshot = @campaign.audience_snapshot || CampaignAudienceSnapshot.create!(
          campaign: @campaign, source_spec: { "sources" => [] }, status: "ready", completed_at: Time.current
        )
        recipient = CampaignRecipient.create!(
          campaign: @campaign, audience_snapshot: snapshot, channel: "sms",
          channel_address: "+251911#{format("%06d", suffix == "first" ? 1 : 2)}",
          channel_address_digest: Digest::SHA256.hexdigest("#{suffix}-digest"), source_type: "contact_list",
          eligibility_status: "eligible", quantity: 1
        )
        CampaignDelivery.create!(
          campaign: @campaign, campaign_recipient: recipient, channel: "sms", status: "pending",
          idempotency_key_digest: Digest::SHA256.hexdigest("delivery-#{suffix}")
        )
      end
    end
  end
end
