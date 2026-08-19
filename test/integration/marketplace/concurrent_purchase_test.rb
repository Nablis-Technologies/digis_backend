# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ConcurrentPurchaseTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ResaleReservationTestHelpers

    setup do
      setup_resale_reservation_context
    end

    teardown do
      Ticketing::TicketTransfer.where(ticket_id: @ticket.id).delete_all
      cleanup_resale_reservation_fixture
    end

    test "only one buyer reserves the listing" do
      race = run_database_race(worker_count: 2) do |index|
        buyer = index.zero? ? @buyer : @second_buyer
        ReserveListing.call(
          listing: Marketplace::ResaleListing.find(@listing.id),
          buyer: Core::User.find(buyer.id),
          idempotency_key: "concurrent-reservation-#{buyer.id}-#{SecureRandom.hex(4)}"
        )
      end
      results = race.results

      assert_empty race.errors, race.errors.inspect
      assert_equal 1, results.count(&:success?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal 1, results.count(&:failure?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal "listing_reserved", results.find(&:failure?).error.code
      assert_equal 1, ResaleListing.where(ticket_id: @ticket.id, status: "reserved").count
      assert_equal 1, Orders::Order.where(sales_channel: "resale", event_id: @event.id).count
    end

    test "transfer and resale reservation cannot both win the ticket transition" do
      race = run_database_race do |index|
        if index.zero?
          ReserveListing.call(
            listing: Marketplace::ResaleListing.find(@listing.id),
            buyer: Core::User.find(@buyer.id),
            idempotency_key: "conflict-resale-#{SecureRandom.hex(4)}"
          )
        else
          Ticketing::Transfers::Initiate.call(
            ticket: Ticketing::Ticket.find(@ticket.id), actor: Core::User.find(@owner.id),
            phone: Core::User.find(@second_buyer.id).phone,
            idempotency_key: "conflict-transfer-#{SecureRandom.hex(4)}"
          )
        end
      end

      assert_empty race.errors, race.errors.inspect
      assert_operator race.results.count(&:success?), :<=, 1
      assert_operator Ticketing::TicketTransfer.where(ticket_id: @ticket.id, status: "pending").count, :<=, 1
      assert_operator ResaleListing.where(ticket_id: @ticket.id, status: "reserved").count, :<=, 1
    end
  end
end
