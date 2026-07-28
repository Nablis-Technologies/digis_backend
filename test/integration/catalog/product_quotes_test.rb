# frozen_string_literal: true

require "test_helper"

class CatalogProductQuotesTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  setup do
    @event = events_events(:ready_listing)
    @product = Catalog::Products::Create.new(
      event: @event,
      attributes: { name: "Festival Pass", type: "ticket" },
      ticket_type_attributes: {
        audience: "public", approval_mode: "automatic",
        date_selection: "fixed", admissions_per_unit: 1
      }
    ).call.value
  end

  test "creates a product price" do
    post "/catalog/product_prices",
         params: { product_id: @product.id, type: "override", currency: "USD",
                   amount_minor: 2500, active_from: Time.current.iso8601 }.to_json,
         headers: admin_headers.merge("Content-Type" => "application/json")

    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal "USD", data["currency"]
    assert_equal 2500, data["amount_minor"]
    assert_equal "override", data["type"]
  end

  test "returns a deterministic quote for a product" do
    Catalog::ProductPrice.create!(
      event_product: @product, type: "override", currency: "USD",
      amount_minor: 2500, active_from: 1.day.ago
    )
    post "/catalog/product_quotes",
         params: { product_id: @product.id, charge_currency: "USD" }.to_json,
         headers: admin_headers.merge("Content-Type" => "application/json")

    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal "USD", data["charge_currency"]
    assert_equal 2500, data["amount_minor"]
    assert_equal "override", data["source_type"]
  end

  test "requires authentication" do
    post "/catalog/product_quotes",
         params: { product_id: @product.id, charge_currency: "USD" }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end
end
