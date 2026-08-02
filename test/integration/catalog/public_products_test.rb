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
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial"
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
      refute product.key?("status")
      refute product.key?("held_count")
      refute product.key?("sold_count")
      refute product.key?("lock_version")
    end

    test "private events do not expose public products" do
      @event.update_columns(visibility: "private")

      get "/public/events/#{@event.slug}/products", as: :json

      assert_response :not_found
    end
  end
end
