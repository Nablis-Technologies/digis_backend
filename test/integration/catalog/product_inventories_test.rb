# frozen_string_literal: true

require "test_helper"

module Catalog
  class ProductInventoriesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Core::CrudTestHelpers

    setup do
      @event = events_events(:ready_listing)
        @product = Catalog::EventProduct.create!(
          event: @event,
          name: "Inventory Test Product",
          type: "merchandise",
          min_per_order: 1,
          schedule_change_refund_policy: "full_or_partial"
        )
      @inventory = Catalog::ProductInventory.create!(
        event_product: @product,
        capacity: 50
      )
    end

    test "requires authentication" do
      get product_inventories_url
      assert_response :unauthorized
    end

    test "admin can list inventories" do
      get product_inventories_url, headers: admin_headers
      assert_response :success
    end

    test "admin can show inventory" do
      get product_inventory_url(@inventory), headers: admin_headers
      assert_response :success
      data = response.parsed_body["data"]
      assert_equal @inventory.id, data["id"]
      assert_equal 50, data["capacity"]
    end

    test "event owner can see operational inventory counters" do
      @inventory.update!(held_count: 3, sold_count: 4)

      get product_inventory_url(@inventory), headers: owner_headers

      assert_response :success
      data = response.parsed_body["data"]
      assert_equal 3, data["held_count"]
      assert_equal 4, data["sold_count"]
    end

    test "attendee cannot list raw inventory definitions" do
      get product_inventories_url, headers: user_headers
      assert_response :forbidden
    end
  end
end
