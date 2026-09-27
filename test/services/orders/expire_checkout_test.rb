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
      assert_equal "expired", @registration.reload.status
      assert_nil @registration.next_action_snapshot
      assert_equal 0, @access_code.reload.used_count
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
      assert_equal "pending_payment", @registration.reload.status
      assert_equal 1, @access_code.reload.used_count
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
      product_result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Expiry ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "access_code", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        price_attributes: {
          type: "base", currency: "ETB", amount_minor: 10_000, active_from: @now - 1.minute
        },
        inventory_configuration: { mode: "event_wide", capacity: 2 }
      )
      assert_predicate product_result, :success?, product_result.error&.message
      draft_product = product_result.value
      event_date = @event.event_dates.create!(
        name: "Expiry ticket date #{SecureRandom.hex(3)}",
        starts_at: @now + 1.day,
        ends_at: @now + 1.day + 2.hours,
        status: "scheduled"
      )
      draft_product.product_accesses.create!(event_date:, type: "venue")
      activation = Catalog::Products::Activate.call(
        product: draft_product, actor: core_users(:super_admin)
      )
      assert_predicate activation, :success?, activation.error&.message
      @product = activation.value
      @ticket_type = @product.ticket_type
      @registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: @buyer,
        created_by: @buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        next_action_snapshot: "requires_order",
        submitted_at: @now
      )
      raw_code = "EXPIRY-CODE-#{SecureRandom.hex(4)}"
      @access_code = Ticketing::AccessCode.create!(
        ticket_type: @ticket_type,
        code: raw_code,
        code_digest: Ticketing::AccessCode.code_digest_for(event_id: @event.id, code: raw_code),
        max_uses: 5,
        used_count: 1,
        max_quantity_per_use: 1,
        active: true
      )
      @registration.update!(access_code: @access_code)
      @item = Orders::OrderItem.create!(
        order: @order,
        event_product: @product,
        registration: @registration,
        name_snapshot: @product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 10_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 10_000,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 10_000,
        fulfillment_status: "pending"
      )
      @inventory = @product.inventories.first
      @inventory.update!(held_count: 1)
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
