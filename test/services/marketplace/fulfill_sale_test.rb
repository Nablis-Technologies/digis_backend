# frozen_string_literal: true

require "test_helper"

module Marketplace
  class FulfillSaleTest < ActiveSupport::TestCase
    include ResaleFulfillmentTestHelpers

    setup do
      setup_resale_fulfillment_context
    end

    test "fulfills a resale exactly once and replaces the seller generation" do
      subject = lambda do
        result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
        assert_predicate result, :success?, result.error&.errors&.inspect || result.error&.message
        result
      end

      assert_idempotent(subject, counter: -> { ResaleSale.where(resale_listing_id: @listing.id).count })

      sale = ResaleSale.find_by!(resale_listing_id: @listing.id)
      ticket = @ticket.reload
      buyer_generation = ticket.current_credential_generation.reload

      assert_equal "completed", sale.status
      assert_equal @payment.id, sale.accepted_payment_id
      assert_equal 2_500, sale.gross_amount_minor
      assert_equal 300, sale.marketplace_fee_minor
      assert_equal 2_200, sale.seller_proceeds_minor
      assert_equal 2_500, @order.reload.settlement_total_minor
      assert_equal "sold", @listing.reload.status
      assert_equal "fulfilled", @order.reload.status
      assert_equal "resale_purchase", ticket.current_acquisition_type
      assert_equal @buyer.id, ticket.owner_user_id
      assert_equal @order_item.id, ticket.current_acquisition_order_item_id
      assert_equal 2_500, ticket.current_acquisition_product_value_minor
      assert_equal 1, ticket.completed_resale_count
      assert_equal @seller_generation.version + 1, buyer_generation.version
      assert_equal "group", buyer_generation.mode
      assert_equal "active", buyer_generation.status
      assert_equal "revoked", @seller_generation.reload.status
      assert_equal "active", buyer_generation.credentials.sole.status
      assert_not ticket.package_suspended?
      assert_empty ticket.admission_slots.reload.select(&:assigned_user_id)

      ledger = SellerLedgerEntry.where(resale_sale_id: sale.id).order(:type).to_a
      assert_equal [ "marketplace_fee", "resale_proceeds" ], ledger.map(&:type)
      assert_equal [ -300, 2_500 ], ledger.map(&:amount_minor)
      assert_empty Finance::LedgerEntry.where(event_id: @event.id, order_id: @order.id)
      assert_empty Catalog::InventoryReservation.where(order_item_id: @order_item.id)
      assert_empty Catalog::VenueCapacityReservation.where(order_item_id: @order_item.id)
      assert_equal "committed", Ticketing::PurchaseLimitAllocation.find_by!(
        registration_id: @order_item.registration_id
      ).status
      assert_equal 1, Core::AuditLog.where(
        action: "marketplace.resale_sale.completed", auditable_id: sale.id
      ).count
      assert_equal 1, Core::OutboxEvent.where(
        event_type: "marketplace.resale_sale.completed", aggregate_id: sale.id
      ).count
    end

    test "rejects a succeeded payment that was not accepted" do
      @payment.update_columns(accepted_at: nil)

      result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)

      assert_predicate result, :failure?
      assert_equal "payment_not_accepted", result.error.code
      assert_equal "reserved", @listing.reload.status
      assert_equal @owner.id, @ticket.reload.owner_user_id
      assert_equal 0, @ticket.reload.completed_resale_count
      assert_empty ResaleSale.where(resale_listing_id: @listing.id)
    end

    test "rolls back the complete transfer when audit publication fails" do
      failure = Core::BaseService::Result.failure(
        Core::BusinessError.new("audit unavailable", code: "audit_unavailable", status: :service_unavailable)
      )
      audit_success = Core::BaseService::Result.success(nil)
      Core::Audit::Record.expects(:call).twice.returns(audit_success, failure)

      result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)

      assert_predicate result, :failure?
      assert_equal "audit_unavailable", result.error.code
      assert_equal "reserved", @listing.reload.status
      assert_equal @owner.id, @ticket.reload.owner_user_id
      assert_equal "primary_purchase", @ticket.reload.current_acquisition_type
      assert_equal 0, @ticket.reload.completed_resale_count
      assert_empty ResaleSale.where(resale_listing_id: @listing.id)
      assert_empty SellerLedgerEntry.where(event_id: @event.id)
      assert_equal "reserved", Ticketing::PurchaseLimitAllocation.find_by!(
        registration_id: @order_item.registration_id
      ).status
      assert_predicate @ticket.reload, :package_suspended?
    end

    test "the Orders fulfillment boundary uses resale fulfillment without ticket issuance" do
      result = Orders::FulfillOrder.call(order: @order, payment: @payment)

      assert_predicate result, :success?, result.error&.errors&.inspect || result.error&.message
      assert ResaleSale.exists?(resale_listing_id: @listing.id)
      assert_empty Ticketing::Ticket.where(order_item_id: @order_item.id)
      assert_empty Core::OutboxEvent.where(
        aggregate_id: @order.id, event_type: "orders.payment.fulfilled"
      )
    end
  end
end
