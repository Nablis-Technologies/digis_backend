# frozen_string_literal: true

require "test_helper"

module Catalog
  class CatalogAuthorizationMatrixTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Authorization product",
        type: "merchandise",
        status: "draft",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial"
      )
      Catalog::ProductPrice.create!(
        event_product: @product,
        type: "base",
        currency: "ETB",
        amount_minor: 1_000,
        active_from: 1.hour.ago
      )
      Catalog::ProductInventory.create!(event_product: @product, capacity: 25)
    end

    test "organizer can list catalog products while attendee cannot" do
      get "/events/#{@event.id}/event_products", headers: owner_headers, as: :json
      assert_response :success

      get "/events/#{@event.id}/event_products", headers: user_headers, as: :json
      assert_response :not_found
    end

    test "attendee cannot read raw pricing or inventory definitions" do
      get "/catalog/product_prices", headers: user_headers, as: :json
      assert_response :forbidden

      get "/catalog/product_inventories", headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "event managers can read catalog products but staff cannot" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event,
        user: core_users(:attendee),
        organization: @event.organization,
        role: "manager",
        status: "active"
      )

      get "/events/#{@event.id}/event_products", headers: user_headers, as: :json
      assert_response :success

      assignment.update!(role: "staff")
      get "/events/#{@event.id}/event_products", headers: user_headers, as: :json
      assert_response :not_found
    end
  end
end
