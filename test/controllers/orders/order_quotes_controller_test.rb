# frozen_string_literal: true

require "test_helper"

module Orders
  class OrderQuotesControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Commercial::GovernanceTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update!(status: "published", visibility: "public")
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = create_product
    end

    test "returns a buyer-safe encrypted quote token and omits commercial internals" do
      post "/events/#{@event.id}/order_quotes",
           params: quote_params,
           headers: user_headers,
           as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert data.fetch("quote_token").present?
      assert_equal "ETB", data.fetch("charge_currency")
      assert_equal 1_000, data.fetch("subtotal_minor")
      assert_equal 1_010, data.fetch("total_minor")
      refute data.key?("commercial_results")
      refute data.key?("organizer_fee_total")
      refute data.key?("provider")
      refute data.key?("promotion_quote")
    end

    test "requires buyer authority for the event" do
      @event.update!(visibility: "private")

      post "/events/#{@event.id}/order_quotes",
           params: quote_params,
           headers: user_headers,
           as: :json

      assert_response :forbidden
    end

    test "requires authentication" do
      post "/events/#{@event.id}/order_quotes", params: quote_params, as: :json

      assert_response :unauthorized
    end

    test "returns the date availability error for a past event date selection" do
      event_date = @event.event_dates.create!(
        starts_at: @quoted_at - 1.day,
        ends_at: @quoted_at - 1.day + 2.hours,
        status: "completed"
      )

      post "/events/#{@event.id}/order_quotes",
           params: quote_params(event_date_ids: [ event_date.id ]),
           headers: user_headers,
           as: :json

      assert_response :conflict
      assert_equal "event_date_unavailable", response.parsed_body.fetch("code")
    end

    private

    def quote_params(event_date_ids: nil)
      item = { event_product_id: @product.id, quantity: 1 }
      item[:event_date_ids] = event_date_ids if event_date_ids
      {
        charge_currency: "ETB",
        items: [ item ]
      }
    end

    def create_checkout_terms
      schedule = create_schedule(code: "api_checkout_#{SecureRandom.hex(5)}", schedule_type: "platform_default")
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
