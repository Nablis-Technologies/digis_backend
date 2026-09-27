# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ReserveListingTest < ActiveSupport::TestCase
    include ResaleReservationTestHelpers

    setup do
      setup_resale_reservation_context
    end

    test "reserves the listing with a buyer order and seller access invalidation" do
      result = ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "reserve-listing-#{SecureRandom.hex(8)}"
      )

      assert_predicate result, :success?, result.error&.message
      order = result.value
      item = order.order_items.first
      buyer_registration = item.registration

      assert_equal "resale", order.sales_channel
      assert_equal "pending_payment", order.status
      assert_equal 2_500, order.subtotal_minor
      assert_equal 150, order.fee_minor
      assert_equal 2_650, order.total_minor
      assert_equal @listing.id, item.resale_listing_id
      assert_equal 1, item.quantity
      assert_equal @buyer.id, buyer_registration.user_id
      assert_equal 1, Ticketing::Registration.where(id: buyer_registration.id).count
      assert_empty Catalog::InventoryReservation.where(order_item_id: item.id)
      assert_empty Catalog::VenueCapacityReservation.where(order_item_id: item.id)
      assert_equal "reserved", Ticketing::PurchaseLimitAllocation.find_by!(registration_id: buyer_registration.id).status
      assert_equal "committed", @seller_allocation.reload.status
      assert_equal "reserved", @listing.reload.status
      assert_equal order.id, @listing.reserved_order_id
      assert_predicate @ticket.reload, :package_suspended?
      assert_equal "revoked", @ticket.current_credential_generation.reload.status
      assert_equal "revoked", @seller_credential.reload.status
      assert_predicate @seller_index.reload, :removed?
      assert_equal 1, order.order_adjustments.where(type: "processing_fee", charged_to: "buyer").count
    end

    test "replays the same reservation key without duplicating the order or effects" do
      key = "reserve-listing-replay-#{SecureRandom.hex(8)}"
      first = ReserveListing.call(listing: @listing, buyer: @buyer, idempotency_key: key)
      order_count = Orders::Order.where(sales_channel: "resale", buyer_user_id: @buyer.id).count
      registration_count = Ticketing::Registration.where(ticket_type_id: @ticket_type.id, user_id: @buyer.id).count
      allocation_count = Ticketing::PurchaseLimitAllocation.where(user_id: @buyer.id).count

      second = ReserveListing.call(listing: @listing, buyer: @buyer, idempotency_key: key)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal first.value.id, second.value.id
      assert_equal order_count, Orders::Order.where(sales_channel: "resale", buyer_user_id: @buyer.id).count
      assert_equal registration_count, Ticketing::Registration.where(ticket_type_id: @ticket_type.id, user_id: @buyer.id).count
      assert_equal allocation_count, Ticketing::PurchaseLimitAllocation.where(user_id: @buyer.id).count
    end

    test "acquires checkout advisory lock before locking the listing or an order" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "reserve-listing-lock-order-#{SecureRandom.hex(4)}"
      )

      assert_predicate result, :success?, result.error&.message
      ticket_type_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"ticketing_ticket_types".*FOR UPDATE/i)
      end
      advisory_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      listing_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"marketplace_resale_listings".*FOR UPDATE/i)
      end
      order_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i)
      end

      assert_not_nil ticket_type_lock_index, "expected a ticket-type policy lock"
      assert_not_nil advisory_index, "expected the shared checkout advisory lock"
      assert_not_nil listing_lock_index, "expected a listing row lock"
      assert_not_nil order_lock_index, "expected the idempotent order row lock"
      assert_operator ticket_type_lock_index, :<, advisory_index
      assert_operator advisory_index, :<, listing_lock_index
      assert_operator advisory_index, :<, order_lock_index
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "rolls back the reservation when the publication fails" do
      key = "reserve-listing-rollback-#{SecureRandom.hex(8)}"
      failure = Core::BaseService::Result.failure(
        Core::BusinessError.new("publication failed", code: "publication_failed", status: :service_unavailable)
      )

      Core::Audit::Record.expects(:call).returns(failure)
      result = ReserveListing.call(listing: @listing, buyer: @buyer, idempotency_key: key)

      assert_predicate result, :failure?

      assert_equal "active", @listing.reload.status
      assert_nil @listing.reserved_order_id
      assert_empty Orders::Order.where(sales_channel: "resale", buyer_user_id: @buyer.id)
      assert_empty Ticketing::Registration.where(ticket_type_id: @ticket_type.id, user_id: @buyer.id)
      assert_equal "active", @ticket.reload.current_credential_generation.status
      assert_not @ticket.package_suspended?
      assert_not @seller_index.reload.removed
    end

    private

    def setup_resale_reservation_context
      super
      @seller_credential = @ticket.current_credential_generation.credentials.first
      @seller_index = @seller_credential.attendee_index_entry
    end
  end
end
