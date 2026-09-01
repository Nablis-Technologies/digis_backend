# frozen_string_literal: true

require "test_helper"

module Catalog
  module Public
    class ProductAvailabilityTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @at = Time.utc(2026, 9, 1, 12, 0, 0)
      end

      test "returns true for an unlimited product inside its sales window" do
        product = create_product(inventory_mode: "unlimited")

        assert_equal({ product.id => true }, ProductAvailability.for(products: [ product ], at: @at))
      end

      test "returns false for an unlimited product outside its sales window" do
        product = create_product(inventory_mode: "unlimited", sales_start_at: @at + 1.hour)

        assert_equal({ product.id => false }, ProductAvailability.for(products: [ product ], at: @at))
      end

      test "returns true when an inventory pool has capacity" do
        product = create_product(inventory_mode: "event_wide")
        product.inventories.create!(capacity: 3, held_count: 1, sold_count: 1)

        assert_equal({ product.id => true }, ProductAvailability.for(products: [ product ], at: @at))
      end

      test "returns false when every inventory pool is exhausted" do
        product = create_product(inventory_mode: "event_wide_and_per_date")
        date = @event.event_dates.create!(starts_at: @at, ends_at: @at + 2.hours, status: "scheduled")
        product.inventories.create!(capacity: 2, held_count: 1, sold_count: 1)
        product.inventories.create!(event_date: date, capacity: 1, held_count: 0, sold_count: 1)

        assert_equal({ product.id => false }, ProductAvailability.for(products: [ product ], at: @at))
      end

      private

      def create_product(inventory_mode:, sales_start_at: nil)
        Catalog::EventProduct.create!(
          event: @event,
          name: "Availability #{SecureRandom.hex(4)}",
          type: "merchandise",
          status: "active",
          inventory_mode:,
          sales_start_at:,
          schedule_change_refund_policy: "full_or_partial"
        )
      end
    end
  end
end
