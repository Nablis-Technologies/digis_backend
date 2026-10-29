# frozen_string_literal: true

require "test_helper"

module Orders
  class RecordPaymentCallbackTest < ActiveSupport::TestCase
    class FakeAdapter < Payments::Providers::Adapter
      attr_accessor :result
      attr_reader :verify_calls

      def initialize(result)
        @result = result
        @verify_calls = []
      end

      def verify(**arguments)
        @verify_calls << arguments
        result
      end

      def create(**) = Payments::Providers::Result.unknown(raw_status: "pending")
      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")
      def refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")
      def verify_refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")
      def verify_webhook(**) = true
      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }
      def capabilities = { currencies: [ "ETB" ], payment_methods: [ "telebirr" ] }
      def settlement_grace_minutes = 5
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @order = Orders::Order.create!(order_attributes)
      @payment = Orders::Payment.create!(payment_attributes)
      @adapter = FakeAdapter.new(Payments::Providers::Result.success(provider_reference: "ref-1"))
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "verifies the transaction before recording a durable payment event" do
      result = callback

      assert_predicate result, :success?, result.error&.message
      event = result.value
      assert_equal [ { provider_reference: "ref-1", idempotency_key: "tx-ref" } ], @adapter.verify_calls
      assert_equal @payment.id, event.payment_id
      assert_equal "payment.succeeded", event.event_type
      assert_equal "success", event.payload.fetch("status")
      assert Core::OutboxEvent.exists?(event_type: "orders.payment_event.received", aggregate_id: event.id)
    end

    test "deduplicates a repeated verified callback" do
      first = callback
      second = callback

      assert_equal first.value.id, second.value.id
      assert_equal 1, Orders::PaymentEvent.where(provider: "chapa", provider_event_id: first.value.provider_event_id).count
      assert_equal 1, Core::OutboxEvent.where(aggregate_id: first.value.id, event_type: "orders.payment_event.received").count
    end

    test "finds the payment from the transaction reference when ref_id is absent" do
      result = Orders::RecordPaymentCallback.call(
        provider: "chapa", transaction_reference: "tx-ref", provider_reference: nil,
        callback_status: "success"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal @payment.id, result.value.payment_id
      assert_equal "payment.pending", result.value.event_type
      assert_empty @adapter.verify_calls
    end

    test "finds the payment by its persisted provider merchant reference" do
      @payment.update!(provider_merchant_reference: "merchant-ref")

      result = Orders::RecordPaymentCallback.call(
        provider: "chapa", transaction_reference: "merchant-ref", provider_reference: nil,
        callback_status: "success"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal @payment.id, result.value.payment_id
      assert_equal "payment.pending", result.value.event_type
      assert_empty @adapter.verify_calls
    end

    test "verifies with the V2 provider reference while locating by merchant reference" do
      result = Orders::RecordPaymentCallback.call(
        provider: "chapa", transaction_reference: "tx-ref", provider_reference: "ref-1",
        callback_status: "success"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "ref-1", @adapter.verify_calls.sole.fetch(:provider_reference)
    end

    test "records a verified provider failure without accepting payment" do
      @adapter.result = Payments::Providers::Result.failure(failure_code: "declined", raw_status: "failed")

      result = callback

      assert_predicate result, :success?, result.error&.message
      assert_equal "payment.failed", result.value.event_type
      assert_equal "failed", result.value.payload.fetch("status")
      assert_equal "processing", @payment.reload.status
    end

    test "fails when the callback transaction reference has no payment" do
      result = Orders::RecordPaymentCallback.call(
        provider: "chapa", transaction_reference: "unknown-reference", provider_reference: nil,
        callback_status: "success"
      )

      assert_predicate result, :failure?
      assert_equal "payment_not_found", result.error.code
    end

    private

    def callback
      Orders::RecordPaymentCallback.call(
        provider: "chapa", transaction_reference: "tx-ref", provider_reference: "ref-1",
        callback_status: "success"
      )
    end

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "pending_payment",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 10_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 500,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 10_500,
        settlement_currency: "ETB",
        settlement_total_minor: 10_500,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def payment_attributes
      {
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "processing",
        amount_minor: @order.total_minor,
        currency: @order.charge_currency,
        commercial_signature: @order.commercial_signature,
        buyer_fee_minor: 500,
        organizer_fee_minor: 0,
        idempotency_key: "tx-ref",
        provider_merchant_reference: "merchant-ref",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end
  end
end
