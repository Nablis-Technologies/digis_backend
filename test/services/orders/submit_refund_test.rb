# frozen_string_literal: true

require "test_helper"

module Orders
  class SubmitRefundTest < ActiveSupport::TestCase
    class RefundAdapter < Payments::Providers::Adapter
      attr_reader :refund_requests
      attr_accessor :refund_result, :available_balance_value, :refund_error

      def initialize(refund_result: Payments::Providers::Result.success(
        provider_reference: "refund-ref", provider_fee_minor: 25, provider_fee_currency: "ETB"
      ),
                     available_balance: { amount_minor: 100_000, currency: "ETB" }, capabilities: {})
        @refund_result = refund_result
        @available_balance_value = available_balance
        @capabilities = capabilities
        @refund_requests = []
      end

      def refund(**request)
        refund_requests << request
        raise refund_error if refund_error

        refund_result
      end

      def verify_refund(**)
        Payments::Providers::Result.unknown(raw_status: "pending")
      end

      def available_balance(**)
        available_balance_value
      end

      def capabilities = @capabilities
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      Orders::Order.where(event: @event, buyer_user: @buyer).where(status: %w[draft pending_payment]).update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      @refund, @payment = create_refund
      @adapter = RefundAdapter.new
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "submits an immediate refund and keeps the promised buyer amount separate from provider fee" do
      result = Orders::SubmitRefund.call(refund: @refund, reserve_target_minor: 0)

      assert_predicate result, :success?, result.error&.message
      refund = result.value
      assert_equal "succeeded", refund.status
      assert_equal 1_000, refund.amount_minor
      assert_equal 25, refund.provider_fee_minor
      assert_equal "ETB", refund.provider_fee_currency
      assert_equal @refund.idempotency_key, @adapter.refund_requests.sole.fetch(:idempotency_key)
    end

    test "records a provider failure as a terminal failed refund" do
      @adapter.refund_result = Payments::Providers::Result.failure(failure_code: "declined", raw_status: "declined")

      result = Orders::SubmitRefund.call(refund: @refund)

      assert_predicate result, :success?, result.error&.message
      assert_equal "failed", result.value.status
      assert_equal "declined", result.value.pending_reason
      assert_nil result.value.next_retry_at
    end

    test "leaves an unknown provider result processing and never resubmits blindly" do
      now = Time.current.change(usec: 0)
      @adapter.refund_result = Payments::Providers::Result.timeout(raw_status: "gateway_timeout")

      first = Orders::SubmitRefund.call(refund: @refund, now:)
      replay = Orders::SubmitRefund.call(refund: @refund, now: now + 1.minute)

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal "processing", first.value.status
      assert_equal "provider_processing", first.value.pending_reason
      assert_operator first.value.next_retry_at, :>, now
      assert_equal 1, @adapter.refund_requests.length
    end

    test "marks an unfunded refund pending without reducing its amount or calling the provider" do
      @adapter.available_balance_value = { amount_minor: 999, currency: "ETB" }

      result = Orders::SubmitRefund.call(refund: @refund, reserve_target_minor: 0)

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending_funds", result.value.status
      assert_equal "insufficient_funds", result.value.pending_reason
      assert_equal 1_000, result.value.amount_minor
      assert_empty @adapter.refund_requests
    end

    test "includes the estimated provider charge when checking available balance" do
      @adapter.available_balance_value = { amount_minor: 1_024, currency: "ETB" }
      @adapter = RefundAdapter.new(
        available_balance: @adapter.available_balance_value,
        capabilities: { refunds: { fee_estimate_minor: 25 } }
      )
      Payments::Providers::Registry.register("chapa", @adapter)

      result = Orders::SubmitRefund.call(refund: @refund)

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending_funds", result.value.status
      assert_empty @adapter.refund_requests
    end

    test "a zero reserve allows a fully funded refund" do
      @adapter.available_balance_value = { amount_minor: 1_000, currency: "ETB" }

      result = Orders::SubmitRefund.call(refund: @refund, reserve_target_minor: 0)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", result.value.status
      assert_equal 1, @adapter.refund_requests.length
    end

    test "a depleted soft reserve does not block a legitimate refund" do
      @adapter.available_balance_value = { amount_minor: 1_000, currency: "ETB" }

      result = Orders::SubmitRefund.call(refund: @refund, reserve_target_minor: 5_000)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", result.value.status
      assert_equal 1, @adapter.refund_requests.length
    end

    test "submits when the provider has no balance API" do
      @adapter.available_balance_value = nil

      result = Orders::SubmitRefund.call(refund: @refund)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", result.value.status
      assert_equal 1, @adapter.refund_requests.length
    end

    test "rejects a provider without refund capability before changing the obligation" do
      @adapter = RefundAdapter.new(capabilities: { refunds: { supported: false } })
      Payments::Providers::Registry.register("chapa", @adapter)

      result = Orders::SubmitRefund.call(refund: @refund)

      assert_predicate result, :failure?
      assert_equal "provider_refund_unsupported", result.error.code
      assert_equal "created", @refund.reload.status
      assert_empty @adapter.refund_requests
    end

    test "leaves processing when the provider call raises so reconciliation can verify it" do
      @adapter.refund_error = RuntimeError.new("provider unavailable")

      assert_raises RuntimeError do
        Orders::SubmitRefund.call(refund: @refund)
      end

      assert_equal "processing", @refund.reload.status
      assert_equal 1, @adapter.refund_requests.length
    end

    private

    def create_refund
      order = Orders::Order.create!(order_attributes)
      product = Catalog::EventProduct.create!(
        event: @event, name: "Refund submission product #{SecureRandom.hex(4)}",
        type: "merchandise", status: "active"
      )
      item = Orders::OrderItem.create!(
        order:, event_product: product, name_snapshot: product.name, type_snapshot: "merchandise",
        quantity: 1, base_currency: "ETB", base_unit_amount_minor: 1_000,
        charge_currency: "ETB", charge_unit_amount_minor: 1_000, exchange_rate: 1,
        discount_minor: 0, total_minor: 1_000, fulfillment_status: "fulfilled"
      )
      order.update!(status: "fulfilled", paid_at: Time.current)
      payment = Orders::Payment.create!(payment_attributes(order))
      result = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: "event_cancellation",
        idempotency_key: "submit-refund-#{SecureRandom.hex(6)}"
      )
      assert_predicate result, :success?, result.error&.message
      [ result.value, payment ]
    end

    def order_attributes
      {
        event: @event, buyer_user: @buyer, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: 1_000, discount_minor: 0, subsidy_minor: 0, fee_minor: 0,
        tax_minor: 0, adjustment_minor: 0, total_minor: 1_000,
        settlement_currency: "ETB", settlement_total_minor: 1_000, exchange_rate: 1,
        exchange_rate_source: "same_currency", exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now, idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def payment_attributes(order)
      {
        order:, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: order.total_minor, currency: order.charge_currency,
        commercial_signature: order.commercial_signature, buyer_fee_minor: 0, organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}", provider_reference: "provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current, succeeded_at: Time.current,
        settlement_grace_minutes: 5, settlement_grace_expires_at: order.expires_at + 5.minutes
      }
    end
  end
end
