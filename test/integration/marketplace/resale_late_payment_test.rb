# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ResaleLatePaymentTest < ActionDispatch::IntegrationTest
    self.use_transactional_tests = false

    include ResaleFulfillmentTestHelpers

    setup do
      setup_resale_reservation_context
      reservation = ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "late-payment-#{SecureRandom.hex(8)}"
      )
      raise reservation.error.message unless reservation.success?

      @order = reservation.value
      @order_item = @order.order_items.find_by!(resale_listing_id: @listing.id)
      @expiry_at = @listing.reload.reservation_expires_at
    end

    teardown do
      cleanup_resale_fulfillment_fixture
    end

    test "reverses a late success after expiry without transferring ownership" do
      expiry = ExpireReservation.call(listing: @listing, at: @expiry_at)
      assert_predicate expiry, :success?, expiry.error&.message

      @payment = create_accepted_payment(order: @order)
      @payment.update_columns(accepted_at: nil)

      result = Orders::AcceptPayment.call(payment: @payment, at: @expiry_at + 1.second)

      assert_predicate result, :success?, result.error&.message
      reversal = Orders::Refund.find_by!(payment: @payment)
      assert_equal "payment_reversal", reversal.type
      assert_equal "late_payment", reversal.reason_code
      assert_equal @payment.amount_minor, reversal.amount_minor
      assert_equal "expired", @listing.reload.status
      assert_empty ResaleSale.where(resale_listing_id: @listing.id)
      assert_equal @owner.id, @ticket.reload.owner_user_id
      assert_equal "active", @ticket.current_credential_generation.status
      refute_predicate @ticket, :package_suspended?
    end

    test "concurrent expiry and fulfillment produce either one sale or one restoration" do
      @order.update_columns(status: "paid", paid_at: Time.current)
      @payment = create_accepted_payment(order: @order)
      race = run_database_race do |index|
        if index.zero?
          ExpireReservation.call(listing: Marketplace::ResaleListing.find(@listing.id), at: @expiry_at)
        else
          FulfillSale.call(
            listing: Marketplace::ResaleListing.find(@listing.id),
            order: Orders::Order.find(@order.id),
            payment: Orders::Payment.find(@payment.id)
          )
        end
      end
      results = race.results

      assert_empty race.errors, race.errors.inspect
      listing = @listing.reload
      ticket = @ticket.reload
      sale_count = ResaleSale.where(resale_listing_id: listing.id).count
      assert_includes [ "expired", "sold" ], listing.status
      assert_includes [ 0, 1 ], sale_count
      assert_equal(sale_count, listing.status == "sold" ? 1 : 0)
      if listing.status == "sold"
        assert_equal @buyer.id, ticket.owner_user_id
        assert_equal "completed", ResaleSale.find_by!(resale_listing_id: listing.id).status
      else
        assert_equal @owner.id, ticket.owner_user_id
        assert_equal "active", ticket.current_credential_generation.status
        refute_predicate ticket, :package_suspended?
      end
      assert results.all? { |result| result.success? || result.failure? }, results.inspect
    end
  end
end
