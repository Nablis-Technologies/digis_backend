# frozen_string_literal: true

require "test_helper"

module Orders
  class BuildQuoteTest < ActiveSupport::TestCase
    include Commercial::GovernanceTestHelpers

    setup do
      @event = events_events(:draft_concert)
      @buyer = core_users(:attendee)
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
    end

    test "builds an immutable quote with automatic FX and commercial evidence" do
      product = create_product(name: "USD parking", price_minor: 10_001)
      Catalog::ExchangeRate.create!(
        from_currency: "ETB", to_currency: "USD", rate: 0.1,
        effective_from: @quoted_at - 1.day
      )

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "USD",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
      quote = result.value
      assert_equal 1_000, quote.items.first.price_quote.amount_minor
      assert_equal "USD", quote.charge_currency
      assert_equal "ETB", quote.settlement_currency
      assert_equal 1, quote.commercial_results.length
      assert_predicate quote, :frozen?
      assert_predicate quote.items, :frozen?
      assert_predicate quote.commercial_results.first, :frozen?
      assert_equal quote.expires_at, quote.exchange_rate_expires_at
    end

    test "quotes multiple product lines with batched product and price reads" do
      first = create_product(name: "Batch quote first", price_minor: nil)
      second = create_product(name: "Batch quote second", price_minor: 1_500)
      Catalog::ProductPrice.create!(
        event_product: first,
        type: "base",
        currency: "USD",
        amount_minor: 1_000,
        active_from: @quoted_at - 1.hour
      )
      Catalog::ProductPrice.create!(
        event_product: first,
        type: "override",
        currency: "ETB",
        amount_minor: 900,
        active_from: @quoted_at - 1.hour
      )

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [
          { product_id: first.id, quantity: 1 },
          { product_id: second.id, quantity: 2 }
        ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal [ 900, 1_500 ], result.value.items.map { |item| item.price_quote.amount_minor }
      assert_equal 3_900, result.value.subtotal_minor
    end

    test "rejects a quote after the event is cancelled" do
      product = create_product(name: "Cancelled event parking", price_minor: 1_000)
      @event.update!(status: "cancelled")

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "event_cancelled", result.error.code
    end

    test "rejects a selected event date whose start is in the past" do
      event_date = create_event_date(starts_at: @quoted_at - 1.minute)

      assert_quote_rejects_date(event_date.id)
    end

    test "rejects a selected event date at its exact start time" do
      event_date = create_event_date(starts_at: @quoted_at)

      assert_quote_rejects_date(event_date.id)
    end

    test "rejects a selected completed event date even when its start is future" do
      event_date = create_event_date(starts_at: @quoted_at + 1.day, status: "completed")

      assert_quote_rejects_date(event_date.id)
    end

    test "rejects a selected cancelled event date even when its start is future" do
      event_date = create_event_date(starts_at: @quoted_at + 1.day, status: "cancelled")

      assert_quote_rejects_date(event_date.id)
    end

    test "rejects a selected postponed event date until it is scheduled again" do
      event_date = create_event_date(starts_at: @quoted_at + 1.day, status: "postponed")

      assert_quote_rejects_date(event_date.id)
    end

    test "rejects a malformed event date identifier without raising" do
      assert_quote_rejects_date("not-a-uuid")
    end

    test "rejects date-free quotes when every materialized event date is unavailable" do
      create_event_date(starts_at: @quoted_at - 1.day, status: "completed")
      create_event_date(starts_at: @quoted_at + 1.day, status: "cancelled")
      product = create_product(name: "Past event parking", price_minor: 1_000)

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?, "expected event_date_unavailable, got #{result.error&.code || 'success'}"
      assert_equal "event_date_unavailable", result.error.code
    end

    test "allows a date-free quote while a multi-date event has a future date" do
      create_event_date(starts_at: @quoted_at - 1.day, status: "completed")
      create_event_date(starts_at: @quoted_at + 1.day)
      product = create_product(name: "Multi-date parking", price_minor: 1_000)

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
    end

    test "allows selecting a future date while another event date is completed" do
      create_event_date(starts_at: @quoted_at - 1.day, status: "completed")
      future_date = create_event_date(starts_at: @quoted_at + 1.day)
      product = create_product(name: "Future-date parking", price_minor: 1_000)

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1, event_date_ids: [ future_date.id ] } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
    end

    test "rejects a ticket quote for a registration that is no longer payable" do
      product, registration = create_ticket_registration(status: "expired")

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, registration_id: registration.id, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "registration_not_payable", result.error.code
    end

    test "accepts a recipient-owned gift registration only with explicit trusted scope" do
      product, registration = create_ticket_registration(
        status: "gift_pending_claim",
        user: core_users(:support)
      )

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, registration_id: registration.id, quantity: 1 } ],
        gift_registration_ids: [ registration.id ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal registration.id, result.value.items.sole.registration_id
    end

    test "quotes distinct same-product gift lines with stable line identities" do
      product, first_registration = create_ticket_registration(
        status: "gift_pending_claim",
        user: core_users(:support)
      )
      second_registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: product.ticket_type,
        user: core_users(:core_admin),
        created_by: @buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "gift_pending_claim",
        submitted_at: @quoted_at
      )
      first_line_id = "c865cacc-b477-4f4b-851c-c1e64716a740"
      second_line_id = "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8"

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [
          { product:, registration_id: first_registration.id, line_id: first_line_id, quantity: 1 },
          { product:, registration_id: second_registration.id, line_id: second_line_id, quantity: 1 }
        ],
        gift_registration_ids: [ first_registration.id, second_registration.id ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 2_000, result.value.subtotal_minor
      assert_equal [ first_line_id, second_line_id ].sort, result.value.items.map(&:line_id).sort
      assert_equal [ "client:#{first_line_id}", "client:#{second_line_id}" ].sort,
        result.value.items.map(&:line_key).sort
    end

    test "rejects repeated ordinary product lines without trusted gift context" do
      product = create_product(name: "Repeated ordinary quote", price_minor: 1_000)

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 }, { product:, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "duplicate_product", result.error.code
    end

    test "applies per-order product limits to the aggregate of gift lines" do
      product, = create_ticket_registration(status: "pending_payment")
      product.update!(max_per_order: 1)
      line_ids = [ "c865cacc-b477-4f4b-851c-c1e64716a740", "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8" ]

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: line_ids.map { |line_id| { product:, line_id:, quantity: 1 } },
        gift_line_ids: line_ids,
        charge_currency: "ETB",
        require_registrations: false,
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "quantity_outside_product_limit", result.error.code
    end

    test "does not map one trusted gift registration to multiple quote lines" do
      product, registration = create_ticket_registration(
        status: "gift_pending_claim",
        user: core_users(:support)
      )
      line_ids = [ "c865cacc-b477-4f4b-851c-c1e64716a740", "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8" ]

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: line_ids.map do |line_id|
          { product:, registration_id: registration.id, line_id:, quantity: 1 }
        end,
        gift_registration_ids: [ registration.id ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "duplicate_product", result.error.code
    end

    test "satisfies a product minimum across separate same-product gift lines" do
      product, = create_ticket_registration(status: "pending_payment")
      product.update!(min_per_order: 2)
      line_ids = [ "c865cacc-b477-4f4b-851c-c1e64716a740", "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8" ]

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: line_ids.map { |line_id| { product:, line_id:, quantity: 1 } },
        gift_line_ids: line_ids,
        charge_currency: "ETB",
        require_registrations: false,
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 2_000, result.value.subtotal_minor
    end

    test "rejects a recipient-owned gift registration when trusted scope is absent" do
      product, registration = create_ticket_registration(
        status: "gift_pending_claim",
        user: core_users(:support)
      )

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, registration_id: registration.id, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "registration_scope_invalid", result.error.code
    end

    test "can preflight a ticket quote without constructing a registration" do
      product, persisted_registration = create_ticket_registration(status: "pending_payment")
      registrations_before = Ticketing::Registration.count

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at,
        require_registrations: false
      )

      assert_predicate result, :success?, result.error&.message
      assert_nil result.value.items.sole.registration_id
      assert_equal product.ticket_type.admissions_per_unit, result.value.items.sole.admissions_per_unit
      assert_equal registrations_before, Ticketing::Registration.count
      assert_predicate persisted_registration, :persisted?
    end

    test "requires a persisted registration for ticket checkout quotes by default" do
      product, = create_ticket_registration(status: "pending_payment")

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "registration_required", result.error.code
    end

    test "quote-only mode preserves the selected date without a registration" do
      product, = create_ticket_registration(status: "pending_payment")
      product.ticket_type.update!(date_selection: "choose_one")
      selected_date_id = product.product_accesses.sole.event_date_id

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1, event_date_ids: [ selected_date_id ] } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at,
        require_registrations: false
      )

      assert_predicate result, :success?, result.error&.message
      assert_nil result.value.items.sole.registration_id
      assert_equal [ selected_date_id.to_s ], result.value.items.sole.event_date_ids.map(&:to_s)
    end

    test "fixed charge-currency override wins without using a base price" do
      product = create_product(name: "Override parking", price_minor: nil)
      Catalog::ProductPrice.create!(
        event_product: product,
        type: "override",
        currency: "ETB",
        amount_minor: 12_500,
        active_from: @quoted_at - 1.hour
      )

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "override", result.value.items.first.price_quote.source_type
      assert_equal 12_500, result.value.items.first.price_quote.amount_minor
    end

    test "rejects an unsupported charge currency with a typed error" do
      product = create_product(name: "Unsupported currency parking", price_minor: 10_000)

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "USD",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?
      assert_equal "unsupported_currency", result.error.code
    end

    test "fails before Commercial resolution when settlement FX is unavailable" do
      product = create_product(name: "Missing settlement FX parking", price_minor: nil)
      Catalog::ProductPrice.create!(
        event_product: product,
        type: "override",
        currency: "USD",
        amount_minor: 1_000,
        active_from: @quoted_at - 1.hour
      )
      commercial_called = false
      resolver = lambda do |**|
        commercial_called = true
        Core::BaseService::Result.failure(
          Core::BusinessError.new("stubbed", code: "commercial_called", status: :unprocessable_entity)
        )
      end

      original_call = Commercial::ResolveCharges.method(:call)
      begin
        Commercial::ResolveCharges.define_singleton_method(:call, resolver)
        result = Orders::BuildQuote.call(
          event: @event,
          buyer: @buyer,
          items: [ { product:, quantity: 1 } ],
          charge_currency: "USD",
          quoted_at: @quoted_at
        )

        assert_predicate result, :failure?
        assert_equal "unsupported_currency", result.error.code
        assert_not commercial_called
      ensure
        Commercial::ResolveCharges.define_singleton_method(:call, original_call)
      end
    end

    test "does not divide by zero for a zero-value promotion" do
      product = create_product(name: "Free promotion parking", price_minor: 0)
      promotion = Catalog::Promotion.create!(
        event: @event,
        name: "Free parking promotion",
        type: "fixed",
        fixed_amount_minor: 0,
        currency: "ETB",
        status: "active",
        per_user_limit: 1
      )
      Catalog::PromotionCode.create!(
        promotion:,
        code: "FREE",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "FREE")
      )

      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1 } ],
        charge_currency: "ETB",
        promotion:,
        promotion_code: "FREE",
        quoted_at: @quoted_at
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 0, result.value.promotion_quote.discount_minor
      assert_equal 0, result.value.items.first.promotion_discount_minor
    end

    private

    def assert_quote_rejects_date(event_date_id)
      product = create_product(name: "Unavailable date #{SecureRandom.hex(3)}", price_minor: 1_000)
      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, quantity: 1, event_date_ids: [ event_date_id ] } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )

      assert_predicate result, :failure?, "expected event_date_unavailable, got #{result.error&.code || 'success'}"
      assert_equal "event_date_unavailable", result.error.code
    end

    def create_checkout_terms
      schedule = create_schedule(
        code: "checkout_#{SecureRandom.hex(5)}",
        schedule_type: "platform_default"
      )
      version = create_version(
        schedule,
        status: "draft",
        effective_from: @quoted_at - 1.day
      )
      create_component(version, label: "Platform commission")
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
      version.update!(
        status: "active",
        activated_by: core_users(:super_admin),
        activated_at: @quoted_at - 1.day
      )
    end

    def create_product(name:, price_minor:)
      product = Catalog::EventProduct.create!(
        event: @event,
        name:,
        type: "parking",
        status: "active",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      if price_minor
        Catalog::ProductPrice.create!(
          event_product: product,
          type: "base",
          currency: "ETB",
          amount_minor: price_minor,
          active_from: @quoted_at - 1.hour
        )
      end
      product
    end

    def create_event_date(starts_at:, status: "scheduled")
      @event.event_dates.create!(
        starts_at:,
        ends_at: starts_at + 2.hours,
        status:
      )
    end

    def create_ticket_registration(status:, user: @buyer)
      product_result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Quote ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        price_attributes: {
          type: "base", currency: "ETB", amount_minor: 1_000, active_from: @quoted_at - 1.minute
        },
        inventory_configuration: { mode: "unlimited" }
      )
      assert_predicate product_result, :success?, product_result.error&.message
      product = product_result.value
      event_date = @event.event_dates.create!(
        name: "Quote ticket date #{SecureRandom.hex(3)}",
        starts_at: @quoted_at + 1.day,
        ends_at: @quoted_at + 1.day + 2.hours,
        status: "scheduled"
      )
      product.product_accesses.create!(event_date:, type: "venue")
      activation = Catalog::Products::Activate.call(product:, actor: core_users(:super_admin))
      assert_predicate activation, :success?, activation.error&.message
      ticket_type = activation.value.ticket_type
      registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type:,
        user:,
        created_by: user,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status:,
        submitted_at: @quoted_at
      )
      [ activation.value, registration ]
    end
  end
end
