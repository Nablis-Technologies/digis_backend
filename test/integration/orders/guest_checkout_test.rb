# frozen_string_literal: true

require "test_helper"

module Orders
  class GuestCheckoutTest < ActionDispatch::IntegrationTest
    include Commercial::GovernanceTestHelpers

    setup do
      create_messaging_policy
      @event = events_events(:draft_concert)
      @event.update!(status: "published", visibility: "public")
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = create_product
      @phone = "0911000041"
      @previous_payment_adapters = Payments::Providers::Registry.instance_variable_get(:@adapters)&.dup
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, @previous_payment_adapters)
    end

    test "creates a phone-bound guest quote and order without authentication" do
      quote_request = {
        phone: @phone,
        phone_confirmation: true,
        charge_currency: "ETB",
        items: [ { event_product_id: @product.id, quantity: 1 } ]
      }

      post "/guest/events/#{@event.id}/order_quotes", params: quote_request, as: :json

      assert_response :success
      quote_data = response.parsed_body.fetch("data")
      assert quote_data.fetch("quote_token").present?
      assert_equal 1_000, quote_data.fetch("subtotal_minor")

      post "/guest/events/#{@event.id}/orders",
           params: { order: { phone: @phone, quote_token: quote_data.fetch("quote_token") } },
           headers: { "Idempotency-Key" => "guest-order-41" },
           as: :json

      assert_response :created
      order_data = response.parsed_body.fetch("data")
      assert_equal "pending_payment", order_data.fetch("status")
      assert_equal "+251911000041", Core::User.find_by(phone: "+251911000041").phone
    end

    test "guest quote requires explicit phone confirmation" do
      post "/guest/events/#{@event.id}/order_quotes",
           params: { phone: @phone, charge_currency: "ETB", items: [ { event_product_id: @product.id, quantity: 1 } ] },
           as: :json

      assert_response :bad_request
      assert_equal "phone_confirmation_required", response.parsed_body.fetch("code")
      assert_nil Core::User.find_by(phone: "+251911000041")
    end

    test "records guest failures so repeated abuse is throttled by IP" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

      10.times do |index|
        post "/guest/events/#{@event.id}/order_quotes",
             params: { phone: "09110000#{500 + index}", charge_currency: "ETB", items: [] },
             headers: { "REMOTE_ADDR" => "198.51.100.41" },
             as: :json
        assert_response :bad_request
      end

      post "/guest/events/#{@event.id}/order_quotes",
           params: { phone: "09110000599", charge_currency: "ETB", items: [] },
           headers: { "REMOTE_ADDR" => "198.51.100.41" },
           as: :json

      assert_response :too_many_requests
      assert_equal "rate_limited", response.parsed_body.fetch("code")
    end

    test "replaying a guest order with the same key returns the original order" do
      post "/guest/events/#{@event.id}/order_quotes",
           params: {
             phone: @phone,
             phone_confirmation: true,
             charge_currency: "ETB",
             items: [ { event_product_id: @product.id, quantity: 1 } ]
           },
           as: :json
      quote_token = response.parsed_body.dig("data", "quote_token")
      order_params = { order: { event_id: @event.id, phone: @phone, quote_token: } }
      headers = { "Idempotency-Key" => "guest-order-replay-41" }

      post "/guest/orders", params: order_params, headers:, as: :json
      first_id = response.parsed_body.dig("data", "id")
      post "/guest/orders", params: order_params, headers:, as: :json

      assert_response :success
      assert_equal first_id, response.parsed_body.dig("data", "id")
      assert_equal 1, Orders::Order.where(buyer_user_id: Core::User.find_by(phone: "+251911000041").id).count
    end

    test "accepted guest payment fulfills and issues exactly one ticket without OTP" do
      ticket_product = create_ticket_product
      registration = Ticketing::Registrations::Submit.call(
        ticket_type: ticket_product.ticket_type,
        actor: nil,
        phone: @phone,
        submission: Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        ),
        audience_proof: {},
        idempotency_key: "guest-ticket-registration-41",
        guest: true,
        phone_confirmation: true
      )
      assert_predicate registration, :success?, registration.error&.message

      post "/guest/events/#{@event.id}/order_quotes",
           params: {
             phone: @phone,
             phone_confirmation: true,
             charge_currency: "ETB",
             items: [ { event_product_id: ticket_product.id,
                        registration_id: registration.value.registration.id, quantity: 1 } ]
           },
           as: :json
      assert_response :success
      quote_token = response.parsed_body.dig("data", "quote_token")

      post "/guest/events/#{@event.id}/orders",
           params: { order: { phone: @phone, quote_token: } },
           headers: { "Idempotency-Key" => "guest-ticket-order-41" },
           as: :json
      assert_response :created
      order = Orders::Order.find(response.parsed_body.dig("data", "id"))

      provider = Payments::Providers::FakePaymentProvider.new(
        outcomes: { create: [ Payments::Providers::Result.success(provider_reference: "guest-payment-41") ] }
      )
      Payments::Providers::Registry.register("chapa", provider)
      post "/guest/orders/#{order.id}/payment_attempts",
           params: {
             payment_attempt: {
               phone: @phone, quote_token:, provider: "chapa", payment_method: "telebirr"
             }
           },
           headers: { "Idempotency-Key" => "guest-payment-attempt-41" },
           as: :json
      assert_response :created
      payment = Orders::Payment.find(response.parsed_body.dig("data", "id"))

      accepted = Orders::AcceptPayment.call(payment:)
      assert_predicate accepted, :success?, accepted.error&.message

      post "/guest/payments/#{payment.id}/refresh",
           params: { payment_refresh: { phone: @phone, quote_token: } },
           headers: { "Idempotency-Key" => "guest-payment-refresh-pending-41" },
           as: :json
      assert_response :success
      assert_equal "no-store", response.headers.fetch("Cache-Control")
      assert_equal "pending", response.parsed_body.dig("data", "state")

      fulfillment = Core::OutboxEvent.find_by!(aggregate_id: order.id, event_type: "orders.payment.fulfilled")
      Core::Outbox::Dispatch.call(event_id: fulfillment.id)

      assert_equal "fulfilled", order.reload.status
      assert_equal 1, Ticketing::Ticket.where(order_item_id: order.order_items.first.id).count
      assert_equal "active", Ticketing::Ticket.where(order_item_id: order.order_items.first.id).first.current_credential_generation.status

      post "/guest/payments/#{payment.id}/refresh",
           params: { payment_refresh: { phone: @phone, quote_token: } },
           headers: { "Idempotency-Key" => "guest-payment-refresh-ready-41" },
           as: :json
      assert_response :success
      assert_equal "ready", response.parsed_body.dig("data", "state")
      assert_equal 1, response.parsed_body.fetch("data").fetch("tickets").length
    end

    private

    def create_checkout_terms
      schedule = create_schedule(code: "guest_checkout_#{SecureRandom.hex(5)}", schedule_type: "platform_default")
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
        funded_by: "organizer",
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
        name: "Guest checkout parking",
        type: "parking",
        status: "active",
        inventory_mode: "event_wide",
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
      Catalog::ProductInventory.create!(event_product: product, capacity: 1)
      product
    end

    def create_ticket_product
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Guest ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        price_attributes: { currency: "ETB", amount_minor: 1_000, active_from: @quoted_at - 1.hour },
        inventory_configuration: { mode: "unlimited" }
      ).value
      event_date = @event.event_dates.create!(
        starts_at: @quoted_at + 1.day,
        ends_at: @quoted_at + 1.day + 2.hours,
        status: "scheduled"
      )
      product.product_accesses.create!(event_date:, type: "venue", usage_limit: 1)
      Catalog::Products::Activate.call(product:, actor: core_users(:super_admin)).value
    end
  end
end
