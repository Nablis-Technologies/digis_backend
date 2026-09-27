# frozen_string_literal: true

require "test_helper"

module Marketplace
  class CancelListingTest < ActiveSupport::TestCase
    include ResaleReservationTestHelpers

    setup do
      setup_resale_reservation_context
    end

    test "acquires checkout advisory lock before listing and order locks" do
      reservation = ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "cancel-listing-lock-order-#{SecureRandom.hex(4)}"
      )
      assert_predicate reservation, :success?, reservation.error&.message

      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = CancelListing.call(
        listing: @listing.reload,
        idempotency_key: "cancel-listing-lock-order-#{SecureRandom.hex(4)}",
        reason: "seller_requested"
      )

      assert_predicate result, :success?, result.error&.message
      advisory_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      listing_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"marketplace_resale_listings".*FOR UPDATE/i)
      end
      order_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i)
      end

      assert_not_nil advisory_index, "expected the shared checkout advisory lock"
      assert_not_nil listing_lock_index, "expected a listing row lock"
      assert_not_nil order_lock_index, "expected a reserved order row lock"
      assert_operator advisory_index, :<, listing_lock_index
      assert_operator advisory_index, :<, order_lock_index
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
