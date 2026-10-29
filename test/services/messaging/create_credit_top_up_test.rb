# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class CreateCreditTopUpTest < ActiveSupport::TestCase
    class FakeAdapter < Payments::Providers::Adapter
      def create(**) = Payments::Providers::Result.unknown(provider_reference: "top-up-ref", checkout_url: "https://checkout.test/top-up")
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
      @requester = core_users(:super_admin)
      @rate = CreditRateVersion.create!(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
        effective_from: 1.hour.ago, status: "active", volume_tiers: [],
        idempotency_key_digest: Digest::SHA256.hexdigest("top-up-rate"),
        request_digest: Digest::SHA256.hexdigest("top-up-rate-request"), activated_at: 1.hour.ago
      )
      Payments::Providers::Registry.register("chapa", FakeAdapter.new)
    end

    teardown { Payments::Providers::Registry.instance_variable_set(:@adapters, {}) }

    test "creates one immutable top-up and billing purchase, then starts payment" do
      operation = -> {
        CreateCreditTopUp.call(
          organization: @organization, requester: @requester, channel: "sms", quantity: 10,
          currency: "ETB", provider: "chapa", payment_method: "telebirr", idempotency_key: "top-up-1"
        )
      }

      assert_idempotent(operation, counter: -> { CreditTopUp.count })
      result = operation.call
      assert_predicate result, :success?, result.error&.message
      assert_equal "pending_payment", result.value.fetch(:top_up).status
      assert_equal 1, Orders::BillingPurchase.count
      assert_equal 1, Orders::Payment.count
    end

    test "closes the billing purchase when the provider rejects the payment" do
      adapter = FakeAdapter.new
      adapter.define_singleton_method(:create) { |**| Payments::Providers::Result.failure(failure_code: "declined") }
      Payments::Providers::Registry.register("chapa", adapter)

      result = CreateCreditTopUp.call(
        organization: @organization, requester: @requester, channel: "sms", quantity: 10,
        currency: "ETB", provider: "chapa", payment_method: "telebirr", idempotency_key: "top-up-failed"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "failed", result.value.fetch(:top_up).status
      assert_equal "failed", result.value.fetch(:top_up).billing_purchase.reload.status
    end
  end
end
