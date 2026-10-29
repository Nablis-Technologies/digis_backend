# frozen_string_literal: true

require "test_helper"

module Orders
  class OrderCheckoutPerformanceTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Commercial::GovernanceTestHelpers
    include PerformanceQueryHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update!(status: "published", visibility: "public")
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = create_product
    end

    test "checkout creation stays within the deterministic database query budget" do
      token = quote_token
      queries = count_database_queries do
        post "/events/#{@event.id}/orders",
             params: { order: { quote_token: token } },
             headers: user_headers.merge("Idempotency-Key" => "performance-checkout"),
             as: :json
      end

      assert_response :created
      assert_operator queries, :<=, 100, "checkout creation used #{queries} queries"
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
      schedule = create_schedule(code: "performance_checkout_#{SecureRandom.hex(5)}",
                                 schedule_type: "platform_default")
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
        name: "Performance parking",
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
