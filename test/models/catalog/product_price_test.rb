# frozen_string_literal: true

require "test_helper"

module Catalog
  class ProductPriceTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Festival Pass", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic",
          date_selection: "fixed", admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
    end

    test "currency must be ISO-4217 alpha-3" do
      price = Catalog::ProductPrice.new(
        event_product: @product, type: "base", currency: "usd",
        amount_minor: 100, active_from: Time.current
      )
      assert price.invalid?
      assert_includes price.errors[:currency], "must be a valid ISO 4217 code"
    end

    test "amount_minor must be non-negative and an integer" do
      price = Catalog::ProductPrice.new(
        event_product: @product, type: "base", currency: "USD",
        amount_minor: -5, active_from: Time.current
      )
      assert price.invalid?
      assert_includes price.errors[:amount_minor], "must be greater than or equal to 0"
    end

    test "zero price is allowed" do
      price = Catalog::ProductPrice.new(
        event_product: @product, type: "override", currency: "USD",
        amount_minor: 0, active_from: Time.current
      )
      assert price.valid?
    end

    test "type must be base or override" do
      price = Catalog::ProductPrice.new(
        event_product: @product, type: "bogus", currency: "USD",
        amount_minor: 100, active_from: Time.current
      )
      assert price.invalid?
      assert_includes price.errors[:type], "is not included in the list"
    end

    test "active_from is required" do
      price = Catalog::ProductPrice.new(
        event_product: @product, type: "base", currency: "USD", amount_minor: 100
      )
      assert price.invalid?
      assert_includes price.errors[:active_from], "can't be blank"
    end

    test "active in-memory price selection includes its start and excludes its end" do
      at = Time.utc(2026, 10, 5, 12)
      price_row = Struct.new(:id, :active_from, :active_to)
      rows = [
        price_row.new("z", at, nil),
        price_row.new("a", at - 1.minute, at + 1.minute),
        price_row.new("b", at - 2.minutes, at),
        price_row.new("c", at + 1.second, nil)
      ]

      active = Catalog::ProductPrice.active_at_in_memory(rows, at:)

      assert_equal %w[a z], active.map(&:id)
    end

    test "overlapping active ranges for the same product/type/currency are rejected" do
      Catalog::ProductPrice.create!(
        event_product: @product, type: "base", currency: "USD",
        amount_minor: 100, active_from: 2.days.ago, active_to: 2.days.from_now
      )
      duplicate = Catalog::ProductPrice.new(
        event_product: @product, type: "base", currency: "USD",
        amount_minor: 200, active_from: 1.day.ago, active_to: 1.day.from_now
      )
      assert duplicate.invalid?, "expected overlapping active range to be invalid"
      assert_includes duplicate.errors[:active_range], "overlaps an existing active price"
    end
  end
end
