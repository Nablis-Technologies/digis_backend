# frozen_string_literal: true

require "test_helper"

module Orders
  class RestartCheckoutTest < ActiveSupport::TestCase
    include Commercial::GovernanceTestHelpers

    setup do
      @event = events_events(:draft_concert)
      @buyer = core_users(:attendee)
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = create_product
      @quote = build_quote
      @order = create_order("restart-source")
    end

    test "releases the old holds and creates one linked replacement" do
      result = restart("restart-1")

      assert_predicate result, :success?, result.error&.message
      replacement = result.value
      assert_equal @order.id, replacement.replaces_order_id
      assert_equal "cancelled", @order.reload.status
      assert_equal "buyer_restart", @order.closed_reason
      assert_equal 1, Orders::Order.active_checkouts.where(event: @event, buyer_user: @buyer).count
      assert_equal "released", Catalog::InventoryReservation.where(order_item_id: @order.order_items.first.id).pick(:status)
      assert Core::OutboxEvent.exists?(aggregate: @order, event_type: "orders.checkout.restarted")
    end

    test "replays a restart idempotently without a second replacement" do
      first = restart("restart-replay")
      assert_predicate first, :success?, first.error&.message

      assert_no_difference -> { Orders::Order.count } do
        replay = restart("restart-replay", order: @order.reload)
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
      end
    end

    test "restarting an active ticket checkout retains the registration and audience proof" do
      buyer = core_users(:support)
      product, ticket_type = create_ticket_product
      access_code = Ticketing::AccessCode.create!(
        ticket_type:,
        code_digest: Ticketing::AccessCode.code_digest_for(
          event_id: @event.id, code: "RESTART-CODE-#{SecureRandom.hex(4)}"
        ),
        max_uses: 5,
        used_count: 1,
        max_quantity_per_use: 1,
        active: true
      )
      registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type:,
        user: buyer,
        created_by: buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        next_action_snapshot: "requires_order",
        submitted_at: @quoted_at,
        access_code:
      )
      quote_result = Orders::BuildQuote.call(
        event: @event,
        buyer:,
        items: [ { product:, registration_id: registration.id, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate quote_result, :success?, quote_result.error&.message
      source_result = Orders::CreateCheckout.call(
        quote: quote_result.value,
        event: @event,
        buyer:,
        idempotency_key: "ticket-restart-source-#{SecureRandom.hex(4)}"
      )
      assert_predicate source_result, :success?, source_result.error&.message

      replacement = Orders::RestartCheckout.call(
        old_order: source_result.value,
        buyer:,
        quote: quote_result.value,
        idempotency_key: "ticket-restart-#{SecureRandom.hex(4)}"
      )

      assert_predicate replacement, :success?, "#{replacement.error&.code}: #{replacement.error&.message}"
      assert_equal "pending_payment", registration.reload.status
      assert_equal 1, access_code.reload.used_count
      assert_equal registration.id, replacement.value.order_items.sole.registration_id
    end

    test "limits replacements to two per buyer and event in a rolling hour" do
      first = restart("restart-limit-1")
      assert_predicate first, :success?, first.error&.message

      second = Orders::RestartCheckout.call(
        old_order: first.value,
        buyer: @buyer,
        quote: @quote,
        idempotency_key: "restart-limit-2"
      )
      assert_predicate second, :success?, second.error&.message

      third = Orders::RestartCheckout.call(
        old_order: second.value,
        buyer: @buyer,
        quote: @quote,
        idempotency_key: "restart-limit-3"
      )
      assert_predicate third, :failure?
      assert_equal "checkout_restart_limit_exceeded", third.error.code
    end

    test "rolls back the source closure and released holds when replacement validation fails" do
      @product.update!(status: "retired")

      result = restart("restart-invalid")

      assert_predicate result, :failure?
      assert_equal "product_unavailable", result.error.code
      assert_equal "pending_payment", @order.reload.status
      assert_equal "held", Catalog::InventoryReservation.where(order_item_id: @order.order_items.first.id).pick(:status)
      assert_equal 0, Orders::Order.where(replaces_order_id: @order.id).count
    end

    private

    def restart(key, order: @order, quote: @quote)
      Orders::RestartCheckout.call(
        old_order: order,
        buyer: @buyer,
        quote:,
        idempotency_key: key
      )
    end

    def create_order(key)
      result = Orders::CreateCheckout.call(
        quote: @quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: key
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def build_quote
      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product: @product, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def create_checkout_terms
      schedule = create_schedule(code: "restart_#{SecureRandom.hex(5)}", schedule_type: "platform_default")
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
        name: "Restart parking",
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
      result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Restart ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "access_code", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        price_attributes: {
          type: "base", currency: "ETB", amount_minor: 1_000, active_from: @quoted_at - 1.hour
        },
        inventory_configuration: { mode: "unlimited" }
      )
      assert_predicate result, :success?, result.error&.message
      product = result.value
      event_date = @event.event_dates.create!(
        name: "Restart ticket date #{SecureRandom.hex(3)}",
        starts_at: @quoted_at + 1.day,
        ends_at: @quoted_at + 1.day + 2.hours,
        status: "scheduled"
      )
      product.product_accesses.create!(event_date:, type: "venue")
      activated = Catalog::Products::Activate.call(product:, actor: core_users(:super_admin))
      assert_predicate activated, :success?, activated.error&.message
      [ activated.value, activated.value.ticket_type ]
    end
  end
end
