# frozen_string_literal: true

require "test_helper"

module Orders
  class CreateCheckoutTest < ActiveSupport::TestCase
    include Commercial::GovernanceTestHelpers

    setup do
      create_messaging_policy
      @event = events_events(:draft_concert)
      @buyer = core_users(:attendee)
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = create_product
      @quote = build_quote
    end

    test "creates one immutable commercial checkout with shared inventory holds" do
      checkout_key = "checkout-#{SecureRandom.hex(6)}"
      result = Orders::CreateCheckout.call(
        quote: @quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: checkout_key
      )

      assert_predicate result, :success?, result.error&.message
      order = result.value
      assert_equal "pending_payment", order.status
      assert_equal 1_000, order.subtotal_minor
      assert_equal 10, order.fee_minor
      assert_equal 1_010, order.total_minor
      assert_equal 925, order.settlement_total_minor
      assert_equal Orders::CommercialSignature.call(
        commercial_results: @quote.commercial_results,
        charge_currency: @quote.charge_currency
      ), order.commercial_signature
      assert_equal 3, order.order_adjustments.count
      assert_equal 1, Catalog::InventoryReservation.where(order_item_id: order.order_items.first.id).count
      assert_equal 1, @product.inventories.reload.first.held_count
      assert Core::OutboxEvent.exists?(aggregate: order, event_type: "orders.checkout.created")

      replay = Orders::CreateCheckout.call(
        quote: @quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: checkout_key,
        at: @quote.expires_at + 1.minute
      )
      assert_predicate replay, :success?, replay.error&.message
      assert_equal order.id, replay.value.id
    end

    test "acquires checkout advisory before event and order locks" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = Orders::CreateCheckout.call(
        quote: @quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: "checkout-lock-order-#{SecureRandom.hex(4)}"
      )

      assert_predicate result, :success?, result.error&.message
      event_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"events_events".*FOR UPDATE/i)
      end
      advisory_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      order_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i)
      end

      assert_not_nil event_lock_index, "expected the event-domain lock"
      assert_not_nil advisory_index, "expected the shared checkout advisory lock"
      assert_not_nil order_lock_index, "expected an order idempotency lock"
      assert_operator advisory_index, :<, event_lock_index
      assert_operator advisory_index, :<, order_lock_index
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "rejects an expired quote without creating an order" do
      expired_quote = Orders::Quote.new(
        commercial_results: @quote.commercial_results,
        items: @quote.items,
        charge_currency: @quote.charge_currency,
        settlement_currency: @quote.settlement_currency,
        quoted_at: 20.minutes.ago,
        expires_at: 10.minutes.ago,
        subtotal_minor: @quote.subtotal_minor,
        discount_minor: @quote.discount_minor,
        buyer_fee_total: @quote.buyer_fee_total,
        organizer_fee_total: @quote.organizer_fee_total,
        subsidy_total: @quote.subsidy_total,
        total_minor: @quote.total_minor,
        settlement_total_minor: @quote.settlement_total_minor,
        exchange_rate: @quote.exchange_rate,
        exchange_rate_source: @quote.exchange_rate_source,
        exchange_rate_quoted_at: @quote.exchange_rate_quoted_at,
        exchange_rate_expires_at: @quote.exchange_rate_expires_at
      )

      result = Orders::CreateCheckout.call(
        quote: expired_quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: "expired-#{SecureRandom.hex(6)}"
      )

      assert_predicate result, :failure?, "expected quote_expired, got #{result.error&.code || 'success'}"
      assert_equal "quote_expired", result.error.code
      assert_equal 0, Orders::Order.where(buyer_user: @buyer, event: @event).count
    end

    test "rejects a previously quoted checkout after the event is cancelled" do
      @event.update!(status: "cancelled")

      result = Orders::CreateCheckout.call(
        quote: @quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: "cancelled-checkout-#{SecureRandom.hex(6)}"
      )

      assert_predicate result, :failure?
      assert_equal "event_cancelled", result.error.code
      assert_equal 0, Orders::Order.where(buyer_user: @buyer, event: @event).count
    end

    test "rejects checkout when its selected date starts after the quote was built" do
      event_date = create_event_date(starts_at: @quoted_at + 5.minutes, venue_capacity: 1)
      quote = build_quote(event_date_ids: [ event_date.id ])
      order_count = Orders::Order.count

      result = Orders::CreateCheckout.call(
        quote:,
        event: @event,
        buyer: @buyer,
        idempotency_key: "date-passed-#{SecureRandom.hex(6)}",
        at: @quoted_at + 6.minutes
      )

      assert_predicate result, :failure?, "expected event_date_unavailable, got #{result.error&.code || 'success'}"
      assert_equal "event_date_unavailable", result.error.code
      assert_equal order_count, Orders::Order.count
      assert_equal 0, @product.inventories.sole.reload.held_count
      assert_empty Catalog::InventoryReservation.where(product_inventory: @product.inventories)
      assert_empty Catalog::VenueCapacityReservation.where(event_date:)
    end

    test "replays an existing checkout after its selected date becomes unavailable" do
      event_date = create_event_date(starts_at: @quoted_at + 5.minutes, venue_capacity: 1)
      quote = build_quote(event_date_ids: [ event_date.id ])
      key = "date-replay-#{SecureRandom.hex(6)}"
      created = Orders::CreateCheckout.call(
        quote:,
        event: @event,
        buyer: @buyer,
        idempotency_key: key,
        at: @quoted_at
      )
      assert_predicate created, :success?, created.error&.message

      replay = Orders::CreateCheckout.call(
        quote:,
        event: @event,
        buyer: @buyer,
        idempotency_key: key,
        at: @quoted_at + 6.minutes
      )

      assert_predicate replay, :success?, replay.error&.message
      assert_equal created.value.id, replay.value.id
      assert_equal 1, Catalog::InventoryReservation.where(
        order_item_id: created.value.order_items.sole.id
      ).count
    end

    test "rejects a stale registration but preserves an exact existing-order replay" do
      product, registration = create_ticket_registration
      quote_result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, registration_id: registration.id, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate quote_result, :success?, quote_result.error&.message
      key = "ticket-registration-checkout-#{SecureRandom.hex(6)}"
      created = Orders::CreateCheckout.call(
        quote: quote_result.value,
        event: @event,
        buyer: @buyer,
        idempotency_key: key
      )
      assert_predicate created, :success?, created.error&.message

      created.value.update!(status: "expired", closed_reason: "checkout_expired")
      registration.update!(status: "expired", next_action_snapshot: nil)

      replay = Orders::CreateCheckout.call(
        quote: quote_result.value,
        event: @event,
        buyer: @buyer,
        idempotency_key: key
      )
      stale_request = Orders::CreateCheckout.call(
        quote: quote_result.value,
        event: @event,
        buyer: @buyer,
        idempotency_key: "new-stale-registration-#{SecureRandom.hex(6)}"
      )

      assert_predicate replay, :success?, replay.error&.message
      assert_equal created.value.id, replay.value.id
      assert_predicate stale_request, :failure?
      assert_equal "registration_not_payable", stale_request.error.code
      assert_equal 1, Orders::Order.where(buyer_user: @buyer, event: @event).count
    end

    test "snapshots cross-currency promotion bounds in the charge currency" do
      Catalog::ExchangeRate.create!(
        from_currency: "ETB", to_currency: "USD", rate: 0.1,
        effective_from: @quoted_at - 1.hour
      )
      promotion = Catalog::Promotion.create!(
        event: @event,
        name: "Cross-currency discount",
        type: "fixed",
        fixed_amount_minor: 100,
        currency: "ETB",
        status: "active",
        per_user_limit: 1
      )
      Catalog::PromotionCode.create!(
        promotion:,
        code: "SAVE100",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "SAVE100")
      )

      quote_result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product: @product, quantity: 1 } ],
        charge_currency: "USD",
        promotion:,
        promotion_code: "SAVE100",
        quoted_at: @quoted_at
      )
      assert_predicate quote_result, :success?, quote_result.error&.message

      checkout = Orders::CreateCheckout.call(
        quote: quote_result.value,
        event: @event,
        buyer: @buyer,
        idempotency_key: "cross-currency-#{SecureRandom.hex(6)}"
      )

      assert_predicate checkout, :success?, checkout.error&.message
      adjustment = checkout.value.order_adjustments.find_by!(type: "discount")
      assert_equal(-10, adjustment.amount_minor)
      assert_equal 10, adjustment.fixed_amount_minor
      assert_equal "ETB", adjustment.resolution_evidence.dig("scope", "promotion_currency")
      assert_equal "USD", adjustment.resolution_evidence.dig("scope", "charge_currency")
    end

    test "fulfills a zero-total checkout and commits its holds" do
      @product.update!(name: "Free parking")
      @product.prices.update_all(amount_minor: 0)
      free_quote = build_quote

      result = Orders::CreateCheckout.call(
        quote: free_quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: "free-#{SecureRandom.hex(6)}"
      )

      assert_predicate result, :success?, result.error&.message
      order = result.value
      assert_equal "fulfilled", order.status
      assert order.paid_at.present?
      assert_equal "committed", Catalog::InventoryReservation.where(order_item_id: order.order_items.first.id).pick(:status)
      assert_equal 1, @product.inventories.reload.first.sold_count
    end

    test "fulfills a zero-total ticket checkout and publishes issuance" do
      @product.update!(name: "Free parking")
      @product.prices.update_all(amount_minor: 0)
      date = @event.event_dates.create!(
        starts_at: @quoted_at + 1.hour, ends_at: @quoted_at + 3.hours, status: "scheduled"
      )
      @product.product_accesses.create!(event_date: date, type: "parking", usage_limit: 1)

      free_quote_result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product: @product, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate free_quote_result, :success?, free_quote_result.error&.message
      free_quote = free_quote_result.value

      result = Orders::CreateCheckout.call(
        quote: free_quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: "free-ticket-#{SecureRandom.hex(6)}"
      )

      assert_predicate result, :success?, result.error&.message
      order = result.value
      assert_equal "fulfilled", order.reload.status
      outbox = Core::OutboxEvent.find_by!(
        aggregate_id: order.id, event_type: "orders.payment.fulfilled"
      )

      assert_difference -> { Ticketing::Ticket.count }, 1 do
        dispatch = Core::Outbox::Dispatch.call(event_id: outbox.id)
        assert_predicate dispatch, :success?, dispatch.error&.message
      end

      ticket = Ticketing::Ticket.find_by!(order_item_id: order.order_items.first.id)
      assert_equal "active", ticket.current_credential_generation.status
      credential = ticket.current_credential_generation.credentials.active.sole
      assert credential.qr_token.present?
      assert credential.lookup_code.present?
      assert_equal 0, Orders::Payment.where(order:).count
      assert_equal 0, Finance::LedgerEntry.where(order:).count
    end

    test "fulfills a zero-total ticket checkout when the ticket has no per-user limit" do
      product, registration = create_ticket_registration
      product.prices.update_all(amount_minor: 0)
      registration.ticket_type.update!(max_packages_per_user: nil)
      quote_result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product:, registration_id: registration.id, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate quote_result, :success?, quote_result.error&.message

      result = Orders::CreateCheckout.call(
        quote: quote_result.value,
        event: @event,
        buyer: @buyer,
        idempotency_key: "free-ticket-without-limit-#{SecureRandom.hex(6)}"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "fulfilled", result.value.status
      assert_equal 0, result.value.total_minor
      assert_empty Ticketing::PurchaseLimitAllocation.where(registration:)
      assert_equal 0, Orders::Payment.where(order: result.value).count
    end

    private

    def create_checkout_terms
      schedule = create_schedule(
        code: "checkout_order_#{SecureRandom.hex(5)}",
        schedule_type: "platform_default"
      )
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

    def create_ticket_registration
      product_result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Stale checkout ticket #{SecureRandom.hex(4)}", type: "ticket" },
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
        name: "Stale ticket date #{SecureRandom.hex(3)}",
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
        user: @buyer,
        created_by: @buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        next_action_snapshot: "requires_order",
        submitted_at: @quoted_at
      )
      [ activation.value, registration ]
    end

    def build_quote(event_date_ids: nil)
      item = { product: @product, quantity: 1 }
      item[:event_date_ids] = event_date_ids if event_date_ids
      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ item ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def create_event_date(starts_at:, venue_capacity: nil)
      @event.event_dates.create!(
        starts_at:,
        ends_at: starts_at + 2.hours,
        status: "scheduled",
        venue_capacity:
      )
    end
  end
end
