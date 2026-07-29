# frozen_string_literal: true

require "test_helper"

module Catalog
  class ProductInventoryTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Test Product",
        type: "merchandise",
        min_per_order: 1,
        schedule_change_refund_policy: "full_or_partial"
      )
    end

    test "requires capacity to be non-negative" do
      inv = Catalog::ProductInventory.new(
        event_product: @product,
        capacity: -1
      )
      assert inv.invalid?
      assert_includes inv.errors[:capacity], "must be greater than or equal to 0"
    end

    test "requires held_count to be non-negative" do
      inv = Catalog::ProductInventory.new(
        event_product: @product,
        capacity: 100,
        held_count: -1
      )
      assert inv.invalid?
      assert_includes inv.errors[:held_count], "must be greater than or equal to 0"
    end

    test "requires sold_count to be non-negative" do
      inv = Catalog::ProductInventory.new(
        event_product: @product,
        capacity: 100,
        sold_count: -1
      )
      assert inv.invalid?
      assert_includes inv.errors[:sold_count], "must be greater than or equal to 0"
    end

    test "held plus sold must not exceed capacity" do
      inv = Catalog::ProductInventory.new(
        event_product: @product,
        capacity: 10,
        held_count: 6,
        sold_count: 5
      )
      assert inv.invalid?
      assert_includes inv.errors[:base], "held plus sold count exceeds capacity"
    end

    test "available? returns true when held plus sold is less than capacity" do
      inv = Catalog::ProductInventory.new(
        event_product: @product,
        capacity: 10,
        held_count: 3,
        sold_count: 2
      )
      assert inv.available?
      assert_equal 5, inv.available_quantity
    end

    test "available? returns false at capacity" do
      inv = Catalog::ProductInventory.new(
        event_product: @product,
        capacity: 10,
        held_count: 10,
        sold_count: 0
      )
      assert_not inv.available?
      assert_equal 0, inv.available_quantity
    end

    test "available? returns false when sold equals capacity" do
      inv = Catalog::ProductInventory.new(
        event_product: @product,
        capacity: 10,
        held_count: 0,
        sold_count: 10
      )
      assert_not inv.available?
      assert_equal 0, inv.available_quantity
    end
  end
end
