# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  class StartBillingPaymentAttemptTest < ActiveSupport::TestCase
    class FakeAdapter < Payments::Providers::Adapter
      attr_reader :create_calls
      attr_accessor :result

      def initialize
        @create_calls = []
        @result = Payments::Providers::Result.unknown(
          provider_reference: "billing-checkout", checkout_url: "https://checkout.test/billing"
        )
      end

      def create(**arguments)
        @create_calls << arguments
        result
      end
      def cancel(**) = Payments::Providers::Result.cancelled
      def verify(**) = Payments::Providers::Result.unknown
      def refund(**) = Payments::Providers::Result.unknown
      def verify_refund(**) = Payments::Providers::Result.unknown
      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }
      def capabilities = { currencies: [ "ETB" ], payment_methods: [ "telebirr" ] }
      def settlement_grace_minutes = 5
    end

    setup do
      @organization = organizations_organizations(:one)
      @buyer = core_users(:super_admin)
      @purchase = Orders::BillingPurchase.create!(
        organization: @organization, requested_by: @buyer, kind: "messaging_credit_top_up",
        source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 1_000, price_digest: Digest::SHA256.hexdigest("quote"),
        status: "created", idempotency_key_digest: Digest::SHA256.hexdigest("purchase"),
        expires_at: 30.minutes.from_now
      )
      @adapter = FakeAdapter.new
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown { Payments::Providers::Registry.instance_variable_set(:@adapters, {}) }

    test "persists a billing attempt before provider I/O and replays its key" do
      first = start("billing-attempt")
      replay = start("billing-attempt")

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal 1, @adapter.create_calls.length
      assert_equal @purchase.id, first.value.billing_purchase_id
      assert_nil first.value.order_id
    end

    test "returns a typed failure when the billing purchase has expired" do
      @purchase.update!(expires_at: 1.minute.ago)

      result = start("expired-billing-attempt")

      assert_predicate result, :failure?
      assert_equal "billing_purchase_expired", result.error.code
      assert_equal :conflict, result.error.status
    end

    test "returns a typed failure when the attempt limit is reached" do
      @adapter.result = Payments::Providers::Result.unknown
      3.times do |index|
        Orders::Payment.create!(
          billing_purchase: @purchase, attempt_number: index + 1, provider: "chapa", payment_method: "telebirr",
          status: index == 2 ? "processing" : "failed", amount_minor: @purchase.amount_minor, currency: @purchase.currency,
          billing_purchase_price_digest: @purchase.price_digest, buyer_fee_minor: 0, organizer_fee_minor: 0,
          idempotency_key: "existing-billing-attempt-#{index}", settlement_grace_minutes: 5,
          settlement_grace_expires_at: @purchase.expires_at + 5.minutes
        )
      end

      result = start("billing-attempt-limit")

      assert_predicate result, :failure?
      assert_equal "payment_attempt_limit_reached", result.error.code
      assert_equal :too_many_requests, result.error.status
    end

    test "returns a typed failure for a conflicting retry" do
      first = start("billing-conflict")
      @purchase.update!(amount_minor: 2_000)

      result = start("billing-conflict")

      assert_predicate first, :success?, first.error&.message
      assert_predicate result, :failure?
      assert_equal "payment_idempotency_conflict", result.error.code
      assert_equal :conflict, result.error.status
    end

    test "keeps an invalid provider result processing for later verification" do
      @adapter.result = Payments::Providers::Result.success(
        provider_reference: "invalid-fee-evidence", provider_fee_minor: 25, provider_fee_currency: "USD"
      )

      result = start("billing-invalid-provider-result")

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", result.value.status
      assert_equal "provider_result_invalid", result.value.raw_status
    end

    private

    def start(key)
      StartBillingPaymentAttempt.call(
        billing_purchase: @purchase, buyer: @buyer, provider: "chapa",
        payment_method: "telebirr", idempotency_key: key
      )
    end
  end
end
