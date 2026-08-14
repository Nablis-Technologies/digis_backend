# frozen_string_literal: true

require "test_helper"

module Orders
  class CreatePaymentReversalTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @order = Orders::Order.create!(order_attributes)
      @payment = Orders::Payment.create!(payment_attributes)
    end

    test "creates a full reversal for a duplicate payment" do
      assert_reversal_reason("duplicate_payment")
    end

    test "creates a full reversal for a late payment" do
      assert_reversal_reason("late_payment")
    end

    test "creates a full reversal for a superseded attempt" do
      assert_reversal_reason("superseded_attempt")
    end

    test "is idempotent by the unaccepted payment and publishes one obligation" do
      first = Orders::CreatePaymentReversal.call(
        payment: @payment, reason_code: "late_payment"
      )
      replay = Orders::CreatePaymentReversal.call(
        payment: @payment, reason_code: "duplicate_payment"
      )

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal "late_payment", replay.value.reason_code
      assert_equal 1, Orders::Refund.where(payment: @payment).count
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_type: "Orders::Payment", aggregate_id: @payment.id,
        event_type: "orders.payment_reversal.created"
      ).count
    end

    test "rejects a reversal for an accepted or non-succeeded payment" do
      @payment.update_columns(accepted_at: Time.current)
      accepted = Orders::CreatePaymentReversal.call(
        payment: @payment, reason_code: "late_payment"
      )

      assert_predicate accepted, :failure?
      assert_equal "payment_not_reversible", accepted.error.code

      @payment.update_columns(accepted_at: nil, status: "failed")
      failed = Orders::CreatePaymentReversal.call(
        payment: @payment, reason_code: "late_payment"
      )

      assert_predicate failed, :failure?
      assert_equal "payment_not_reversible", failed.error.code
      assert_empty Orders::Refund.where(payment: @payment)
    end

    test "rejects a voluntary or unknown reason" do
      result = Orders::CreatePaymentReversal.call(
        payment: @payment, reason_code: "change_of_mind"
      )

      assert_predicate result, :failure?
      assert_equal "invalid_reversal_reason", result.error.code
      assert_empty Orders::Refund.where(payment: @payment)
    end

    test "does not change order fulfillment or other payment-owned state" do
      original_order_status = @order.status
      original_paid_at = @order.paid_at
      original_payment_status = @payment.status

      result = Orders::CreatePaymentReversal.call(
        payment: @payment, reason_code: "duplicate_payment"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal original_order_status, @order.reload.status
      assert_nil original_paid_at
      assert_nil @order.paid_at
      assert_equal original_payment_status, @payment.reload.status
      assert_nil @payment.accepted_at
      assert_empty @order.order_items
    end

    private

    def assert_reversal_reason(reason)
      result = Orders::CreatePaymentReversal.call(payment: @payment, reason_code: reason)

      assert_predicate result, :success?, result.error&.message
      assert_equal "payment_reversal", result.value.type
      assert_equal @payment.amount_minor, result.value.amount_minor
      assert_equal reason, result.value.reason_code
      assert_empty result.value.refund_items
    end

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "pending_payment",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 1_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 1_000,
        settlement_currency: "ETB",
        settlement_total_minor: 1_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def payment_attributes(order: @order)
      {
        order:,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor: order.total_minor,
        currency: order.charge_currency,
        commercial_signature: order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}",
        provider_reference: "provider-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: order.expires_at + 5.minutes
      }
    end
  end
end
