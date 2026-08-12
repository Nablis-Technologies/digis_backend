# frozen_string_literal: true

require "test_helper"

module Orders
  class ExpireCheckoutTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @now = Time.current.change(usec: 0)
      Orders::Order.where(event: @event, buyer_user: @buyer).active_checkouts.update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      build_checkout_graph
    end

    test "expires and releases a checkout immediately when it has no current attempt" do
      result = ExpireCheckout.call(now: @now)

      assert_predicate result, :success?, result.error&.message
      assert_equal 1, result.value
      assert_equal "expired", @order.reload.status
      assert_equal "checkout_expired", @order.closed_reason
      assert @reservation.reload.released?
      assert_equal "released", @redemption.reload.status
      assert_equal 0, @inventory.reload.held_count
      assert_no_enqueued_jobs only: Orders::ExpireSettlementGraceJob
    end

    test "moves only the current attempt's checkout group into bounded settlement grace" do
      payment = create_payment(grace_minutes: 3)
      grace_deadline = payment.settlement_grace_expires_at

      result = ExpireCheckout.call(now: @now)

      assert_predicate result, :success?, result.error&.message
      assert_equal 1, result.value
      assert_equal "pending_payment", @order.reload.status
      assert_equal "processing", @reservation.reload.status
      assert_equal grace_deadline, @reservation.reload.expires_at
      assert_equal "reserved", @redemption.reload.status
      assert_equal grace_deadline, @redemption.reload.expires_at
      assert_equal 1, @inventory.reload.held_count
      assert_enqueued_with(job: Orders::ExpireSettlementGraceJob, args: [ payment.id ])
    end

    test "uses the provider snapshot at the fifteen minute platform cap" do
      payment = create_payment(grace_minutes: 15)

      result = ExpireCheckout.call(now: @now)

      assert_predicate result, :success?, result.error&.message
      assert_equal payment.settlement_grace_expires_at, @reservation.reload.expires_at
      assert_equal @order.expires_at + 15.minutes, payment.settlement_grace_expires_at
    end

    private

    def build_checkout_graph
      @order = Orders::Order.create!(order_attributes)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Expiry parking",
        type: "parking",
        status: "active",
        inventory_mode: "event_wide"
      )
      @item = Orders::OrderItem.create!(
        order: @order,
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: @product.type,
        quantity: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 10_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 10_000,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 10_000,
        fulfillment_status: "pending"
      )
      @inventory = Catalog::ProductInventory.create!(
        event_product: @product,
        capacity: 2,
        held_count: 1
      )
      @reservation = Catalog::InventoryReservation.create!(
        product_inventory: @inventory,
        order_item_id: @item.id,
        reservation_group_id: @item.id,
        quantity: 1,
        admissions_per_unit: 1,
        status: "held",
        expires_at: @order.expires_at,
        request_fingerprint: "a" * 64
      )
      @promotion = Catalog::Promotion.create!(
        event: @event,
        name: "Expiry promotion",
        type: "fixed",
        fixed_amount_minor: 100,
        currency: "ETB",
        per_user_limit: 1,
        status: "active"
      )
      @promotion_code = Catalog::PromotionCode.create!(
        promotion: @promotion,
        code: "EXPIRE10",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "EXPIRE10")
      )
      @redemption = Orders::PromotionRedemption.create!(
        order: @order,
        promotion: @promotion,
        promotion_code: @promotion_code,
        user: @buyer,
        status: "reserved",
        discount_minor: 100,
        currency: "ETB",
        idempotency_key: "expiry-redemption-#{@order.id}",
        expires_at: @order.expires_at
      )
      @order.update!(status: "pending_payment")
    end

    def create_payment(grace_minutes:)
      Orders::Payment.create!(
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "processing",
        amount_minor: @order.total_minor,
        currency: "ETB",
        commercial_signature: @order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        provider_reference: "expiry-ref-#{SecureRandom.hex(4)}",
        idempotency_key: "expiry-payment-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: grace_minutes,
        settlement_grace_expires_at: @order.expires_at + grace_minutes.minutes
      )
    end

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 10_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 10_000,
        settlement_currency: "ETB",
        settlement_total_minor: 10_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: @now + 1.hour,
        expires_at: @now - 1.second,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end
  end
end
