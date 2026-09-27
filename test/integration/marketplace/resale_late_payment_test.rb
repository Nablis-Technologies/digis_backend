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

    test "accepts resale payment after locking ticket type before checkout and order" do
      payment = Orders::Payment.create!(
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "processing",
        amount_minor: @order.total_minor,
        currency: @order.charge_currency,
        commercial_signature: @order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "resale-payment-lock-#{SecureRandom.hex(8)}",
        provider_reference: "resale-lock-#{SecureRandom.hex(8)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      )
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = Orders::AcceptPayment.call(payment:)

      assert_predicate result, :success?, result.error&.message
      ticket_type_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"ticketing_ticket_types".*FOR UPDATE/i)
      end
      checkout_lock_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      order_lock_index = statements.index { |sql| sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i) }

      assert_not_nil ticket_type_lock_index, "expected the resale ticket-type lock"
      assert_not_nil checkout_lock_index, "expected the shared checkout advisory lock"
      assert_not_nil order_lock_index, "expected the order row lock"
      assert_operator ticket_type_lock_index, :<, checkout_lock_index
      assert_operator checkout_lock_index, :<, order_lock_index
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
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
