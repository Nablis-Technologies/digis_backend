# frozen_string_literal: true

require "test_helper"

module Marketplace
  class FreezeChargebackProceedsTest < ActiveSupport::TestCase
    include AcquisitionChainTestHelpers

    setup do
      setup_acquisition_chain_context
    end

    test "freezes the current seller proceeds and suspends the current package" do
      subject = lambda do
        FreezeChargebackProceeds.call(
          payment: @second_payment,
          actor: @manager,
          idempotency_key: "chargeback-current-#{@second_payment.id}"
        )
      end

      assert_idempotent(subject, counter: -> { SellerLedgerEntry.where(type: "chargeback").count })

      result = subject.call
      assert_predicate result, :success?, result.error&.message
      assert_equal "chargeback", result.value.type
      assert_equal(-2_000, result.value.amount_minor)
      assert_equal "chargeback_review", @ticket.ticket_suspensions.active.sole.reason_code
      assert @ticket.reload.package_suspended?
      assert_equal @second_buyer.id, @ticket.owner_user_id
      assert_equal second_order_item_id, @ticket.current_acquisition_order_item_id
    end

    test "does not suspend or replace the current credential for an older acquisition chargeback" do
      result = FreezeChargebackProceeds.call(
        payment: @payment,
        actor: @manager,
        idempotency_key: "chargeback-older-#{@payment.id}"
      )

      assert_predicate result, :success?, result.error&.message
      assert_not @ticket.reload.package_suspended?
      assert_equal @second_buyer.id, @ticket.owner_user_id
      assert_equal second_order_item_id, @ticket.current_acquisition_order_item_id
      assert_empty Ticketing::TicketSuspension.where(ticket_id: @ticket.id, status: "active")
      assert_equal @first_sale.seller_user_id, result.value.seller_user_id
      assert_equal(-2_500, result.value.amount_minor)
    end

    private

    def second_order_item_id
      @second_order.order_items.find_by!(resale_listing_id: @second_listing.id).id
    end
  end
end
