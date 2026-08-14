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
      cleanup_resale_reservation_fixture
    end

    test "only one buyer reserves the listing" do
      ready = Queue.new
      start = Queue.new
      threads = [ @buyer, @second_buyer ].map do |buyer|
        Thread.new do
          ready << true
          start.pop
          ActiveRecord::Base.connection_pool.with_connection do
            ReserveListing.call(
              listing: Marketplace::ResaleListing.find(@listing.id),
              buyer: Core::User.find(buyer.id),
              idempotency_key: "concurrent-reservation-#{buyer.id}-#{SecureRandom.hex(4)}"
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.count(&:success?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal 1, results.count(&:failure?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal "listing_reserved", results.find(&:failure?).error.code
      assert_equal 1, ResaleListing.where(ticket_id: @ticket.id, status: "reserved").count
      assert_equal 1, Orders::Order.where(sales_channel: "resale", event_id: @event.id).count
    ensure
      threads&.each(&:join)
    end
  end
end
