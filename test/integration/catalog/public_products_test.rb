# frozen_string_literal: true

require "test_helper"

module Catalog
  class PublicProductsTest < ActionDispatch::IntegrationTest
    setup do
      @event = events_events(:ready_listing)
      @event.update_columns(status: "published", visibility: "public")
      @active_product = Catalog::EventProduct.create!(
        event: @event,
        name: "Public active product",
        description: "Visible to attendees",
        type: "merchandise",
        status: "active",
        inventory_mode: "event_wide",
        schedule_change_refund_policy: "full_or_partial"
      )
      @active_product.update!(metadata: { requires_ticket: true, internal_flag: "hidden" })
      Catalog::ProductPrice.create!(
        event_product: @active_product, type: "base", currency: "ETB",
        amount_minor: 1_500, active_from: 1.hour.ago
      )
      Catalog::ProductPrice.create!(
        event_product: @active_product, type: "override", currency: "USD",
        amount_minor: 1_200, active_from: 1.hour.ago
      )
      Catalog::EventProduct.create!(
        event: @event,
        name: "Private draft product",
        type: "merchandise",
        status: "draft",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial"
      )
      Catalog::ProductInventory.create!(event_product: @active_product, capacity: 50, held_count: 3, sold_count: 4)
    end

    test "public event products expose active sale fields without internal counters" do
      get "/public/events/#{@event.slug}/products", as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      product = data.find { |item| item["id"] == @active_product.id }

      assert product
      refute data.any? { |item| item["name"] == "Private draft product" }
      assert_equal "Public active product", product["name"]
      assert_equal [ "ETB", "USD" ], product.fetch("price_options").map { |price| price.fetch("currency") }.sort
      assert_equal 1_500, product.fetch("price_options").find { |price| price["currency"] == "ETB" }.fetch("amount_minor")
      assert_equal true, product.fetch("available")
      refute product.key?("metadata")
      refute product.key?("requires_ticket")
      refute product.key?("status")
      refute product.key?("held_count")
      refute product.key?("sold_count")
      refute product.key?("lock_version")
    end

    test "public products report unavailable when inventory is exhausted" do
      inventory = @active_product.inventories.first
      inventory.update!(held_count: inventory.capacity - inventory.sold_count)

      get "/public/events/#{@event.slug}/products", as: :json

      assert_response :success
      product = response.parsed_body.fetch("data").find { |item| item["id"] == @active_product.id }
      assert_equal false, product.fetch("available")
    end

    test "public products report unavailable outside the sales window" do
      @active_product.update!(sales_start_at: 1.hour.from_now)

      get "/public/events/#{@event.slug}/products", as: :json

      assert_response :success
      product = response.parsed_body.fetch("data").find { |item| item["id"] == @active_product.id }
      assert_equal false, product.fetch("available")
    end

    test "private events do not expose public products" do
      @event.update_columns(visibility: "private")

      get "/public/events/#{@event.slug}/products", as: :json

      assert_response :not_found
    end
  end
end
