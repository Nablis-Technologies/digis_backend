# frozen_string_literal: true

require_relative "resale_fulfillment_test_helpers"

module Marketplace
  module AcquisitionChainTestHelpers
    include ResaleFulfillmentTestHelpers

    def setup_acquisition_chain_context
      setup_resale_fulfillment_context
      @primary_order = @ticket.order_item.order
      @primary_payment = create_accepted_payment(order: @primary_order)

      first_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      raise first_result.error.message unless first_result.success?

      @first_sale = first_result.value
      @second_listing, @second_order, @second_payment, @second_sale = create_followup_resale(
        buyer: @second_buyer,
        asking_amount_minor: 2_000
      )
    end

    private

    def create_followup_resale(buyer:, asking_amount_minor:)
      ticket = @ticket.reload
      listing_result = ActivateListing.call(
        ticket:,
        actor: ticket.owner_user,
        asking_amount_minor:,
        idempotency_key: "acquisition-chain-listing-#{SecureRandom.hex(8)}"
      )
      raise listing_result.error.message unless listing_result.success?

      listing = listing_result.value
      reservation_result = ReserveListing.call(
        listing:,
        buyer:,
        idempotency_key: "acquisition-chain-reservation-#{SecureRandom.hex(8)}"
      )
      raise reservation_result.error.message unless reservation_result.success?

      order = reservation_result.value
      order.update_columns(status: "paid", paid_at: Time.current)
      payment = create_accepted_payment(order:)
      sale_result = FulfillSale.call(listing:, order:, payment:)
      raise sale_result.error.message unless sale_result.success?

      [ listing, order, payment, sale_result.value ]
    end
  end
end
