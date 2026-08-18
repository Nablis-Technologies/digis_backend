# frozen_string_literal: true

require "test_helper"

module Catalog
  class ProductDateAllocationTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                        ends_at: 1.day.from_now + 4.hours)
      @product = Catalog::EventProduct.create!(event: @event, name: "Festival Pass",
                                                type: "merchandise", status: "draft",
                                                inventory_mode: "unlimited")
      @product.product_accesses.create!(event_date: @date, type: "venue")
    end

    test "valid with positive basis points" do
      alloc = Catalog::ProductDateAllocation.new(
        event_product: @product,
        event_date: @date,
        allocation_basis_points: 5_000
      )
      assert alloc.valid?, alloc.errors.full_messages.join(", ")
    end

    test "invalid with zero basis points" do
      alloc = Catalog::ProductDateAllocation.new(
        event_product: @product,
        event_date: @date,
        allocation_basis_points: 0
      )
      refute alloc.valid?
    end

    test "invalid with more than 10000 basis points" do
      alloc = Catalog::ProductDateAllocation.new(
        event_product: @product,
        event_date: @date,
        allocation_basis_points: 10_001
      )
      refute alloc.valid?
    end

    test "enforces unique product-date constraint" do
      Catalog::ProductDateAllocation.create!(
        event_product: @product,
        event_date: @date,
        allocation_basis_points: 5_000
      )
      duplicate = Catalog::ProductDateAllocation.new(
        event_product: @product,
        event_date: @date,
        allocation_basis_points: 5_000
      )
      refute duplicate.valid?
    end

    test "date must belong to same event" do
      other_event = events_events(:draft_concert)
      other_date = Events::EventDate.create!(
        event: other_event,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 4.hours
      )
      alloc = Catalog::ProductDateAllocation.new(
        event_product: @product,
        event_date: other_date,
        allocation_basis_points: 10_000
      )
      refute alloc.valid?
    end
  end
end
