# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ConcurrentResaleSuccessTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ResaleFulfillmentTestHelpers

    setup do
      setup_resale_fulfillment_context
    end

    teardown do
      cleanup_resale_fulfillment_fixture
    end

    test "two accepted-payment callbacks create one sale and one buyer generation" do
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do
        Thread.new do
          ready << true
          start.pop
          ActiveRecord::Base.connection_pool.with_connection do
            FulfillSale.call(
              listing: ResaleListing.find(@listing.id),
              order: Orders::Order.find(@order.id),
              payment: Orders::Payment.find(@payment.id)
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert results.all?(&:success?), results.map { |result| result.error&.code }.inspect
      assert_equal 1, ResaleSale.where(resale_listing_id: @listing.id).count
      assert_equal 1, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).where(status: "active").count
      assert_equal 2, SellerLedgerEntry.where(event_id: @event.id).count
      assert_equal "sold", @listing.reload.status
      assert_equal @buyer.id, @ticket.reload.owner_user_id
    ensure
      threads&.each(&:join)
    end
  end
end
