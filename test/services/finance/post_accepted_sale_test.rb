# frozen_string_literal: true

require "test_helper"

module Finance
  class PostAcceptedSaleTest < ActiveSupport::TestCase
    include LedgerTestHelpers

    setup do
      @order = create_ledger_order
      @payment = create_accepted_payment(order: @order)
    end

    test "posts one gross sale and separate organizer adjustments" do
      create_organizer_adjustment(order: @order)

      result = Finance::PostAcceptedSale.call(payment: @payment, at: Time.current)

      assert_predicate result, :success?, result.error&.message
      entries = Finance::LedgerEntry.where(payment_id: @payment.id).order(:type)
      assert_equal [ "platform_fee", "sale" ], entries.pluck(:type)
      assert_equal [ -500, 10_000 ], entries.pluck(:amount_minor)
      assert_equal @order.settlement_total_minor, entries.sum(&:amount_minor)
      assert entries.all? { |entry| entry.organization_id == @order.event.organization_id }
      assert entries.all? { |entry| entry.event_id == @order.event_id }
    end

    test "replays an accepted payment without duplicating ledger facts" do
      subject = -> { Finance::PostAcceptedSale.call(payment: @payment) }
      assert_idempotent(subject, counter: -> {
        Finance::LedgerEntry.where(payment_id: @payment.id).count
      })

      result = subject.call
      assert_predicate result, :success?, result.error&.message
      assert_equal 1, Finance::LedgerEntry.where(payment_id: @payment.id, type: "sale").count
    end

    test "does not post an unaccepted successful payment" do
      @payment.update_columns(accepted_at: nil)

      result = Finance::PostAcceptedSale.call(payment: @payment)

      assert_predicate result, :success?, result.error&.message
      assert_empty Finance::LedgerEntry.where(payment_id: @payment.id)
    end
  end
end
