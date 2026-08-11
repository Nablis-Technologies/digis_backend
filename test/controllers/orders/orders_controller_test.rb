# frozen_string_literal: true

require "test_helper"

module Orders
  class OrdersControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Commercial::GovernanceTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update!(status: "published", visibility: "public")
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = create_product
    end

    test "creates a checkout from a quote token and hides internal order evidence" do
      token = quote_token

      assert_difference -> { Orders::Order.count }, 1 do
        post "/events/#{@event.id}/orders",
             params: { order: { quote_token: token } },
             headers: user_headers.merge("Idempotency-Key" => "api-checkout-1"),
             as: :json
      end

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "pending_payment", data.fetch("status")
      assert_equal 1_010, data.fetch("total_minor")
      refute data.key?("exchange_rate_source")
      refute data.key?("settlement_total_minor")
      refute data.key?("commercial_results")
      refute data.key?("payment_reference")
      refute data.fetch("adjustments").any? { |adjustment| adjustment.key?("resolution_evidence") }
    end

    test "replays the same checkout idempotency key" do
      token = quote_token
      headers = user_headers.merge("Idempotency-Key" => "api-checkout-replay")
      params = { order: { quote_token: token } }

      post "/events/#{@event.id}/orders", params:, headers:, as: :json
      assert_response :created
      order_id = response.parsed_body.dig("data", "id")

      assert_no_difference -> { Orders::Order.count } do
        post "/events/#{@event.id}/orders", params:, headers:, as: :json
      end

      assert_response :created
      assert_equal order_id, response.parsed_body.dig("data", "id")
    end

    test "rejects a missing idempotency key before creating an order" do
      assert_no_difference -> { Orders::Order.count } do
        post "/events/#{@event.id}/orders",
             params: { order: { quote_token: quote_token } },
             headers: user_headers,
             as: :json
      end

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "rejects a quote token replayed by another buyer" do
      token = quote_token

      assert_no_difference -> { Orders::Order.count } do
        post "/events/#{@event.id}/orders",
             params: { order: { quote_token: token } },
             headers: {
               "Authorization" => "Bearer #{issue_token(:support)}",
               "Idempotency-Key" => "api-checkout-cross-buyer"
             },
             as: :json
      end

      assert_response :unprocessable_entity
      assert_equal "invalid_quote", response.parsed_body.fetch("code")
    end

    test "rejects a second active checkout for the same buyer and event" do
      token = quote_token
      post "/events/#{@event.id}/orders",
           params: { order: { quote_token: token } },
           headers: user_headers.merge("Idempotency-Key" => "api-checkout-active-1"),
           as: :json
      assert_response :created

      post "/events/#{@event.id}/orders",
           params: { order: { quote_token: token } },
           headers: user_headers.merge("Idempotency-Key" => "api-checkout-active-2"),
           as: :json

      assert_response :conflict
      assert_equal "active_checkout_exists", response.parsed_body.fetch("code")
    end

    test "restarts a checkout through the bounded replacement endpoint" do
      token = quote_token
      post "/events/#{@event.id}/orders",
           params: { order: { quote_token: token } },
           headers: user_headers.merge("Idempotency-Key" => "api-checkout-restart-source"),
           as: :json
      assert_response :created
      old_order_id = response.parsed_body.dig("data", "id")
      replacement_token = quote_token

      post "/orders/#{old_order_id}/restart",
           params: { order: { quote_token: replacement_token } },
           headers: user_headers.merge("Idempotency-Key" => "api-checkout-restart"),
           as: :json

      assert_response :created
      replacement = Orders::Order.find(response.parsed_body.dig("data", "id"))
      assert_equal old_order_id, replacement.replaces_order_id
      assert_equal "cancelled", Orders::Order.find(old_order_id).status
    end

    private

    def quote_token
      post "/events/#{@event.id}/order_quotes",
           params: {
             charge_currency: "ETB",
             items: [ { event_product_id: @product.id, quantity: 1 } ]
           },
           headers: user_headers,
           as: :json
      assert_response :success
      response.parsed_body.dig("data", "quote_token")
    end

    def create_checkout_terms
      schedule = create_schedule(code: "api_orders_#{SecureRandom.hex(5)}", schedule_type: "platform_default")
      version = create_version(schedule, effective_from: @quoted_at - 1.day)
      create_component(version, rate_bps: 750, label: "Platform commission")
      create_component(
        version,
        component_type: "buyer_service_fee",
        calculation_type: "percentage",
        charged_to: "buyer",
        funded_by: "buyer",
        basis_type: "eligible_order_subtotal",
        rate_bps: 100,
        label: "Buyer service fee"
      )
      create_component(
        version,
        component_type: "processing_cost_recovery",
        calculation_type: "explicit_zero",
        charged_to: "buyer",
        funded_by: "buyer",
        basis_type: nil,
        rate_bps: nil,
        label: "Processing cost recovery"
      )
      sync_definition_digest(version)
      version.update!(status: "active", activated_by: core_users(:super_admin), activated_at: @quoted_at - 1.day)
    end

    def create_product
      product = Catalog::EventProduct.create!(
        event: @event,
        name: "Checkout parking",
        type: "parking",
        status: "active",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      Catalog::ProductPrice.create!(
        event_product: product,
        type: "base",
        currency: "ETB",
        amount_minor: 1_000,
        active_from: @quoted_at - 1.hour
      )
      product
    end
  end
end
