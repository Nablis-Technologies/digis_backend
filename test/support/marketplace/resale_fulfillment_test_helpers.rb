# frozen_string_literal: true

require_relative "resale_reservation_test_helpers"
require_relative "../finance/ledger_test_helpers"

module Marketplace
  module ResaleFulfillmentTestHelpers
    include ResaleReservationTestHelpers
    include Finance::LedgerTestHelpers

    def setup_resale_fulfillment_context
      setup_resale_reservation_context
      reservation = ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "reserve-fulfillment-#{SecureRandom.hex(8)}"
      )
      raise reservation.error.message unless reservation.success?

      @order = reservation.value
      @order.update_columns(status: "paid", paid_at: Time.current)
      @payment = create_accepted_payment(order: @order)
      @order_item = @order.order_items.find_by!(resale_listing_id: @listing.id)
      @seller_generation = @ticket.current_credential_generation.reload
      @seller_credential = @seller_generation.credentials.first
    end

    def cleanup_resale_fulfillment_fixture
      sale_ids = ResaleSale.where(ticket_id: @ticket.id).pluck(:id)
      payment_ids = Orders::Payment.where(order_id: @order&.id).pluck(:id)
      Core::OutboxEvent.where(aggregate_id: [ @ticket.id, @listing&.id, *sale_ids ].compact).delete_all

      connection = Marketplace::ApplicationRecord.connection
      connection.execute(
        "ALTER TABLE marketplace_seller_ledger_entries DISABLE TRIGGER " \
        "trg_marketplace_seller_ledger_entry_immutable"
      )
      begin
        SellerLedgerEntry.where(resale_sale_id: sale_ids).delete_all
      ensure
        connection.execute(
          "ALTER TABLE marketplace_seller_ledger_entries ENABLE TRIGGER " \
          "trg_marketplace_seller_ledger_entry_immutable"
        )
      end

      connection.execute(
        "ALTER TABLE marketplace_resale_sales DISABLE TRIGGER trg_marketplace_resale_sale_immutable"
      )
      begin
        ResaleSale.where(id: sale_ids).delete_all
      ensure
        connection.execute(
          "ALTER TABLE marketplace_resale_sales ENABLE TRIGGER trg_marketplace_resale_sale_immutable"
        )
      end

      Orders::Payment.where(id: payment_ids).delete_all
      cleanup_resale_reservation_fixture
    end
  end
end
