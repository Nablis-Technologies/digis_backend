# frozen_string_literal: true

require "test_helper"

module Orders
  class ApplyRefundResultTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      Orders::Order.where(event: @event, buyer_user: @buyer).where(status: %w[draft pending_payment]).update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      @refund = create_refund
    end

    test "records a provider fee reported after the refund already succeeded" do
      @refund.update!(status: "succeeded", provider_reference: "refund-ref")
      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.success(
          provider_reference: "refund-ref", provider_fee_minor: 25, provider_fee_currency: "ETB"
        )
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", result.value.status
      assert_equal 1_000, result.value.amount_minor
      assert_equal 25, result.value.provider_fee_minor
      assert_equal "ETB", result.value.provider_fee_currency
    end

    test "replays a duplicate successful provider callback without changing the refund amount" do
      @refund.update!(status: "processing")
      provider_result = Payments::Providers::Result.success(provider_reference: "refund-ref")

      first = Orders::ApplyRefundResult.call(refund: @refund, result: provider_result)
      replay = Orders::ApplyRefundResult.call(refund: @refund, result: provider_result)

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal "succeeded", replay.value.status
      assert_equal 1_000, replay.value.amount_minor
    end

    test "keeps timeout and unknown results processing for later verification" do
      @refund.update!(status: "processing")
      now = Time.current.change(usec: 0)

      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.timeout(
          provider_reference: "maybe-ref", raw_status: "gateway_timeout"
        ), now:
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", result.value.status
      assert_equal "provider_processing", result.value.pending_reason
      assert_equal "maybe-ref", result.value.provider_reference
      assert_operator result.value.next_retry_at, :>, now
    end

    test "records a provider failure without changing the promised amount" do
      @refund.update!(status: "processing")

      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.failure(failure_code: "declined", raw_status: "declined")
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "failed", result.value.status
      assert_equal "declined", result.value.pending_reason
      assert_equal 1_000, result.value.amount_minor
    end

    test "rejects provider fee evidence without a currency and preserves processing state" do
      @refund.update!(status: "processing")

      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.success(provider_reference: "refund-ref", provider_fee_minor: 25)
      )

      assert_predicate result, :failure?
      assert_equal "invalid_provider_result", result.error.code
      assert_equal "processing", @refund.reload.status
      assert_nil @refund.provider_fee_minor
    end

    private

    def create_refund
      order = Orders::Order.create!(
        event: @event, buyer_user: @buyer, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: 1_000, discount_minor: 0, subsidy_minor: 0, fee_minor: 0,
        tax_minor: 0, adjustment_minor: 0, total_minor: 1_000,
        settlement_currency: "ETB", settlement_total_minor: 1_000, exchange_rate: 1,
        exchange_rate_source: "same_currency", exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now, idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      product = Catalog::EventProduct.create!(
        event: @event, name: "Refund result product #{SecureRandom.hex(4)}",
        type: "merchandise", status: "active"
      )
      item = Orders::OrderItem.create!(
        order:, event_product: product, name_snapshot: product.name, type_snapshot: "merchandise",
        quantity: 1, base_currency: "ETB", base_unit_amount_minor: 1_000,
        charge_currency: "ETB", charge_unit_amount_minor: 1_000, exchange_rate: 1,
        discount_minor: 0, total_minor: 1_000, fulfillment_status: "fulfilled"
      )
      order.update!(status: "fulfilled", paid_at: Time.current)
      payment = Orders::Payment.create!(
        order:, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 1_000, currency: "ETB",
        commercial_signature: order.commercial_signature, buyer_fee_minor: 0, organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}", provider_reference: "provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current, succeeded_at: Time.current,
        settlement_grace_minutes: 5, settlement_grace_expires_at: order.expires_at + 5.minutes
      )
      result = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: "event_cancellation",
        idempotency_key: "apply-refund-#{SecureRandom.hex(6)}"
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end
  end
end
