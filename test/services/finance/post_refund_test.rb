# frozen_string_literal: true

require "test_helper"

module Finance
  class PostRefundTest < ActiveSupport::TestCase
    include LedgerTestHelpers

    setup do
      @order = create_ledger_order
      @payment = create_accepted_payment(order: @order)
      Finance::PostAcceptedSale.call(payment: @payment)
      @refund = create_refund_for(order: @order, payment: @payment)
    end

    test "posts a succeeded item refund as one negative settlement entry" do
      result = Finance::PostRefund.call(refund: @refund)

      assert_predicate result, :success?, result.error&.message
      entry = Finance::LedgerEntry.find_by!(refund_id: @refund.id)
      assert_equal "refund", entry.type
      assert_equal(-@refund.amount_minor, entry.amount_minor)
      assert_equal @order.settlement_currency, entry.currency
      assert_equal @order.event_id, entry.event_id
    end

    test "replays a refund without duplicating the negative entry" do
      subject = -> { Finance::PostRefund.call(refund: @refund) }
      assert_idempotent(subject, counter: -> {
        Finance::LedgerEntry.where(refund_id: @refund.id).count
      })

      result = subject.call
      assert_predicate result, :success?, result.error&.message
      assert_equal 1, Finance::LedgerEntry.where(refund_id: @refund.id).count
    end

    test "does not post an unaccepted payment reversal as organizer proceeds" do
      reversal_order = create_ledger_order
      reversal_payment = create_accepted_payment(order: reversal_order)
      reversal_payment.update_columns(accepted_at: nil)
      reversal = Orders::Refund.create!(
        payment: reversal_payment,
        type: "payment_reversal",
        idempotency_key: "ledger-payment-reversal-#{SecureRandom.hex(8)}",
        amount_minor: reversal_payment.amount_minor,
        currency: reversal_payment.currency,
        status: "succeeded",
        reason_code: "late_payment"
      )

      result = Finance::PostRefund.call(refund: reversal)

      assert_predicate result, :success?, result.error&.message
      assert_empty Finance::LedgerEntry.where(refund_id: reversal.id)
    end

    test "posts a chargeback as a negative entry for an accepted payment" do
      result = Finance::PostChargeback.call(payment: @payment, amount_minor: 2_000)

      assert_predicate result, :success?, result.error&.message
      entry = Finance::LedgerEntry.find_by!(payment_id: @payment.id, type: "chargeback")
      assert_equal(-2_000, entry.amount_minor)
      assert_equal @order.settlement_currency, entry.currency
    end

    test "corrects a ledger fact with one linked opposite adjustment" do
      original = Finance::LedgerEntry.find_by!(payment_id: @payment.id, type: "sale")

      result = Finance::ReverseLedgerEntry.call(entry: original)

      assert_predicate result, :success?, result.error&.message
      assert_equal original.id, result.value.reverses_entry_id
      assert_equal(-original.amount_minor, result.value.amount_minor)
      assert_equal "adjustment", result.value.type
    end
  end
end
