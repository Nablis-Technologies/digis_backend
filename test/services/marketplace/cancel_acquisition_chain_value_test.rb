# frozen_string_literal: true

require "test_helper"

module Marketplace
  class CancelAcquisitionChainValueTest < ActiveSupport::TestCase
    include AcquisitionChainTestHelpers

    setup do
      setup_acquisition_chain_context
    end

    test "refunds every acquisition payer and reverses each resale ledger fact" do
      subject = lambda do
        CancelAcquisitionChainValue.call(
          ticket: @ticket,
          idempotency_key: "cancel-acquisition-chain-#{@ticket.id}"
        )
      end

      assert_idempotent(subject, counter: -> { Orders::Refund.count })

      result = subject.call
      assert_predicate result, :success?, result.error&.message

      refunds = Orders::Refund.includes(:payment, :refund_items).order(:created_at, :id).to_a
      assert_equal [ @primary_payment.id, @payment.id, @second_payment.id ], refunds.map(&:payment_id)
      assert_equal [ 3_000, 2_500, 2_000 ], refunds.map(&:amount_minor)
      assert refunds.all? { |refund| refund.reason_code == "event_cancellation" }
      assert refunds.all? { |refund| refund.refund_items.one? }

      assert_equal "cancelled", @first_sale.reload.status
      assert_equal "cancelled", @second_sale.reload.status
      reversals = SellerLedgerEntry.where(resale_sale_id: [ @first_sale.id, @second_sale.id ])
        .where(type: "cancellation_reversal").order(:created_at, :id).to_a
      assert_equal 4, reversals.length
      assert_equal [ -2_500, 300, -2_000, 300 ], reversals.map(&:amount_minor)
      assert_equal [ @first_sale.id, @first_sale.id, @second_sale.id, @second_sale.id ],
        reversals.map(&:resale_sale_id)

      assert_equal @second_buyer.id, @ticket.reload.owner_user_id
      assert_equal second_order_item_id, @ticket.current_acquisition_order_item_id
    end

    test "rejects date-scoped resale cancellation before creating obligations" do
      event_date = Events::EventDate.where(event_id: @event.id).first!
      refund_count = Orders::Refund.count
      ledger_count = SellerLedgerEntry.count

      result = CancelAcquisitionChainValue.call(
        ticket: @ticket,
        event_date:,
        idempotency_key: "date-cancel-acquisition-chain-#{@ticket.id}"
      )

      assert_predicate result, :failure?
      assert_equal "date_scoped_resale_refund_unsupported", result.error.code
      assert_equal refund_count, Orders::Refund.count
      assert_equal ledger_count, SellerLedgerEntry.count
    end

    private

    def second_order_item_id
      @second_order.order_items.find_by!(resale_listing_id: @second_listing.id).id
    end
  end
end
