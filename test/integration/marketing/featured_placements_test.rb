# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  class FeaturedPlacementsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include PerformanceQueryHelpers
    include Marketing::FeaturedPlacementTestHelpers

    class FakeAdapter < Payments::Providers::Adapter
      def create(**) = Payments::Providers::Result.unknown(provider_reference: "featured-ref", checkout_url: "https://checkout.test/featured")
      def cancel(**) = Payments::Providers::Result.cancelled
      def verify(**) = Payments::Providers::Result.unknown
      def refund(**) = Payments::Providers::Result.unknown
      def verify_refund(**) = Payments::Providers::Result.unknown
      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }
      def capabilities = { currencies: [ "ETB" ], payment_methods: [ "telebirr" ] }
      def settlement_grace_minutes = 5
    end

    setup do
      @previous_enabled = Rails.application.config.x.marketing_featured_placements_enabled
      @event = events_events(:ready_listing)
      @organizer = core_users(:super_admin)
      Core::Review.create!(reviewable: @event.organization, context: "verification", status: "approved")
      make_publishable(@event)
      Events::EventDate.where(event_id: @event.id).update_all(
        status: "scheduled", starts_at: 52.hours.from_now, ends_at: 54.hours.from_now
      )
      @event.event_setting.update!(config: { event_type: "rsvp", public_guest_limit: 10 })
      Events::Publish.call(event: @event, actor: @organizer, idempotency_key: SecureRandom.uuid)
      create_active_public_ticket
      @doors_at = Events::EventDate.where(event_id: @event.id, status: "scheduled").minimum(:starts_at)
      @offer = PlacementOffer.create!(
        code: "api_discovery_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 100_001,
        currency: "ETB", minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", status: "active",
        created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
        idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      )
      @capacity_policy = create_active_capacity_policy!(max_concurrent: 4)
      Rails.application.config.x.marketing_featured_placements_enabled = true
      Payments::Providers::Registry.register("chapa", FakeAdapter.new)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
      Rails.application.config.x.marketing_featured_placements_enabled = @previous_enabled
    end

    test "organizers can list offers, quote, and create an idempotent server-priced checkout" do
      get "/events/#{@event.id}/featured_placements/offers", headers: admin_headers, as: :json
      assert_response :success
      assert_equal [ @offer.id ], response.parsed_body.dig("data", "offers").map { |offer| offer.fetch("id") }
      assert response.parsed_body.dig("data", "eligibility", "eligible")

      starts_at = @doors_at - 50.hours
      body = { featured_placement: { offer_id: @offer.id, starts_at: starts_at.iso8601 } }
      post "/events/#{@event.id}/featured_placements/quote", params: body, headers: admin_headers, as: :json
      assert_response :success
      quote = response.parsed_body.fetch("data")
      assert_equal @doors_at.to_i, Time.iso8601(quote.fetch("ends_at")).to_i
      assert_equal 50.hours.to_i, quote.fetch("duration_seconds")
      assert_equal ((100_001 * 50 + 23) / 24), quote.fetch("amount_minor")

      post "/events/#{@event.id}/featured_placements", params: body.merge(
        featured_placement: body.fetch(:featured_placement).merge(amount_minor: 1)
      ), headers: admin_headers, as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      assert_empty FeaturedPlacement.all

      headers = admin_headers.merge("Idempotency-Key" => "featured-api-create-#{SecureRandom.hex(4)}")
      post "/events/#{@event.id}/featured_placements", params: body.merge(
        featured_placement: body.fetch(:featured_placement).merge(amount_minor: 1)
      ), headers:, as: :json
      assert_response :created
      first = response.parsed_body.fetch("data")
      assert_equal quote.fetch("amount_minor"), first.dig("placement", "amount_minor")
      assert_equal "pending_payment", first.dig("placement", "status")
      assert_equal @offer.code, first.dig("placement", "offer_code")
      assert_equal @offer.version, first.dig("placement", "offer_version")
      assert_equal @offer.daily_rate_minor, first.dig("placement", "daily_rate_minor")
      assert_equal @offer.terms_version, first.dig("placement", "terms_version")
      assert_equal "https://checkout.test/featured", first.dig("payment", "checkout_url")
      %w[provider_payload account_number digest request_digest provider_reference].each do |field|
        assert_not first.fetch("placement").key?(field)
      end

      post "/events/#{@event.id}/featured_placements", params: body, headers:, as: :json
      assert_response :created
      assert_equal first.dig("placement", "id"), response.parsed_body.dig("data", "placement", "id")
      assert_equal 1, Orders::BillingPurchase.where(source_type: "Marketing::FeaturedPlacement").count
      assert_equal 1, Orders::Payment.where(billing_purchase_id: Orders::BillingPurchase.last.id).count

      get "/events/#{@event.id}/featured_placements", headers: admin_headers, as: :json
      assert_response :success
      assert_equal 1, response.parsed_body.dig("pagination", "total_count")
      assert_equal first.dig("placement", "id"), response.parsed_body.dig("data", 0, "id")
      get "/events/#{@event.id}/featured_placements/#{first.dig('placement', 'id')}", headers: admin_headers, as: :json
      assert_response :success
      assert_equal first.dig("placement", "id"), response.parsed_body.dig("data", "id")
    end

    test "public featured discovery and featured event filter include only accepted paid placements" do
      placement, = create_active_placement

      route = Rails.application.routes.recognize_path("/public/featured_events", method: :get)
      assert_equal "public/events", route.fetch(:controller)
      assert_equal "featured", route.fetch(:action)

      get "/public/featured_events", as: :json
      assert_response :success
      card = response.parsed_body.fetch("data").find { |event| event.fetch("id") == @event.id }
      assert card
      assert_equal "featured", card.fetch("placement_label")
      assert_equal "available", card.fetch("ticket_availability")
      %w[payment placement_id provider_reference billing_purchase_id amount_minor].each do |field|
        assert_not card.key?(field)
      end

      get "/public/events?featured=true", as: :json
      assert_response :success
      assert_equal [ @event.id ], response.parsed_body.fetch("data").map { |event| event.fetch("id") }
      assert_equal "featured", response.parsed_body.dig("data", 0, "placement_label")
      assert_equal 1, response.parsed_body.dig("pagination", "total_count")
      assert_equal "public/events", Rails.application.routes.recognize_path(
        "/public/events?featured=true", method: :get
      ).fetch(:controller)
      assert_equal "public/events", Rails.application.routes.recognize_path(
        "/public/events?featured=false", method: :get
      ).fetch(:controller)

      get "/public/events?featured=false", as: :json
      assert_response :success
      organic_card = response.parsed_body.fetch("data").find { |event| event.fetch("id") == @event.id }
      assert organic_card
      refute organic_card.key?("placement_label")

      placement.update!(status: "pending_payment")
      get "/public/featured_events", as: :json
      assert_response :success
      refute response.parsed_body.fetch("data").any? { |event| event.fetch("id") == @event.id }
    end

    test "featured discovery returns a safe unavailable response when resolution fails" do
      failure = Core::BusinessError.new(
        "internal featured query failure", code: "internal_failure", status: :unprocessable_entity
      )
      Marketing::FeaturedPlacements::PublicQuery.stubs(:call)
        .returns(Core::BaseService::Result.failure(failure))

      get "/public/featured_events", as: :json

      assert_response :service_unavailable
      assert_equal "featured_events_unavailable", response.parsed_body.fetch("code")
      refute response.parsed_body.key?("data")
      refute_includes response.body, "internal featured query failure"
    end

    test "create response uses returned financial records instead of reloading them" do
      placement, purchase, payment = create_active_placement
      result = Core::BaseService::Result.success(
        FeaturedPlacements::Create::Result.new(placement, purchase, payment, false)
      )
      FeaturedPlacements::Create.stubs(:call).returns(result)
      headers = admin_headers.merge("Idempotency-Key" => "featured-in-memory-#{SecureRandom.hex(4)}")
      body = { featured_placement: { offer_id: @offer.id, starts_at: (@doors_at - 48.hours).iso8601 } }

      queries = capture_database_queries do
        post "/events/#{@event.id}/featured_placements", params: body, headers:, as: :json
      end

      assert_response :created
      assert_equal payment.id, response.parsed_body.dig("data", "payment", "id")
      financial_reads = queries.grep(/\b(?:FROM|JOIN)\s+\"?(?:orders_billing_purchases|orders_payments|orders_refunds)\b/i)
      assert_empty financial_reads, "expected create serialization not to query financial records: #{financial_reads}"
    end

    test "organizers cancel through an idempotent route and guests cannot purchase" do
      placement, purchase, payment = create_active_placement
      path = "/events/#{@event.id}/featured_placements/#{placement.id}/cancel"
      post path, params: {}, headers: admin_headers, as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      assert_equal "active", placement.reload.status

      headers = admin_headers.merge("Idempotency-Key" => "featured-api-cancel-#{SecureRandom.hex(4)}")

      post path, params: {}, headers:, as: :json
      assert_response :success
      assert_equal "cancelled", response.parsed_body.dig("data", "status")
      assert_equal "created", response.parsed_body.dig("data", "refund", "status")
      refund_id = response.parsed_body.dig("data", "refund", "id")

      post path, params: {}, headers:, as: :json
      assert_response :success
      assert_equal refund_id, response.parsed_body.dig("data", "refund", "id")
      assert_equal 1, Orders::Refund.where(billing_purchase_id: purchase.id).count

      replay = FeaturedPlacements::Create::Result.new(placement.reload, purchase.reload, payment, true)
      FeaturedPlacements::Create.stubs(:call).returns(Core::BaseService::Result.success(replay))
      create_headers = admin_headers.merge("Idempotency-Key" => "featured-api-create-replay-#{SecureRandom.hex(4)}")
      post "/events/#{@event.id}/featured_placements", params: {
        featured_placement: { offer_id: @offer.id, starts_at: (@doors_at - 48.hours).iso8601 }
      }, headers: create_headers, as: :json
      assert_response :created
      assert_equal refund_id, response.parsed_body.dig("data", "placement", "refund", "id")

      post "/events/#{@event.id}/featured_placements", params: {
        featured_placement: { offer_id: @offer.id, starts_at: @doors_at - 50.hours }
      }, headers: user_headers.merge("Idempotency-Key" => "featured-api-unauthorized"), as: :json
      assert_response :forbidden
      assert_equal "not_authorized", response.parsed_body.fetch("code")
      assert_equal "paid", purchase.reload.status
      assert_predicate payment, :accepted?
    end

    private

    def create_active_public_ticket
      product = Catalog::Products::CreateDraft.call(
        event: @event, actor: @organizer,
        product_attributes: { name: "Featured API RSVP", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        price_attributes: { currency: "ETB", amount_minor: 0, active_from: 1.hour.ago },
        inventory_configuration: { mode: "unlimited" }
      ).value
      product.product_accesses.create!(
        event_date_id: Events::EventDate.where(event_id: @event.id, status: "scheduled").pick(:id),
        type: "venue", usage_limit: nil
      )
      Catalog::Products::Activate.call(product:, actor: @organizer)
    end

    def create_active_placement
      starts_at = Time.current.utc.change(usec: 0) - 1.hour
      ends_at = @doors_at
      duration = (ends_at - starts_at).to_i
      price = (@offer.daily_rate_minor * duration + 86_399) / 86_400
      price_digest = Digest::SHA256.hexdigest("api-paid-price")
      placement = FeaturedPlacement.create!(
        event: @event, organization_id: @event.organization_id, placement_offer: @offer,
        status: "active", surface: "public_discovery", starts_at:, ends_at:, duration_seconds: duration,
        offer_code: @offer.code, offer_version: @offer.version, daily_rate_minor: @offer.daily_rate_minor,
        amount_minor: price, currency: "ETB", terms_version: @offer.terms_version, price_digest:,
        idempotency_key_digest: Digest::SHA256.hexdigest("api-paid-placement"),
        request_digest: Digest::SHA256.hexdigest("api-paid-request")
      )
      purchase = Orders::BillingPurchase.create!(
        organization_id: @event.organization_id, requested_by: @organizer,
        kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
        currency: "ETB", amount_minor: price, price_digest:, status: "paid",
        idempotency_key_digest: Digest::SHA256.hexdigest("api-paid-purchase"), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: price, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "api-paid-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
      )
      [ placement, purchase, payment ]
    end
  end
end
