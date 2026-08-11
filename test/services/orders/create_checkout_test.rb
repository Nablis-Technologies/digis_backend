# frozen_string_literal: true

require "test_helper"

module Orders
  class CreateCheckoutTest < ActiveSupport::TestCase
    include Commercial::GovernanceTestHelpers

    setup do
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

      assert_predicate result, :failure?
      assert_equal "quote_expired", result.error.code
      assert_equal 0, Orders::Order.where(buyer_user: @buyer, event: @event).count
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
      assert_equal "paid", order.status
      assert order.paid_at.present?
      assert_equal "committed", Catalog::InventoryReservation.where(order_item_id: order.order_items.first.id).pick(:status)
      assert_equal 1, @product.inventories.reload.first.sold_count
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
  end
end
