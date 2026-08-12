# frozen_string_literal: true

require "test_helper"

module Orders
  class ExpireSettlementGraceTest < ActiveSupport::TestCase
    class VerificationAdapter < Payments::Providers::Adapter
      attr_accessor :verification_result
      attr_reader :verify_calls

      def initialize(verification_result)
        @verification_result = verification_result
        @verify_calls = []
      end

      def verify(**arguments)
        @verify_calls << arguments
        verification_result
      end

      def create(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")

      def verify_webhook(**) = true

      def refund(**) = Payments::Providers::Result.success(provider_reference: "refund-ref")

      def verify_refund(**) = Payments::Providers::Result.success(provider_reference: "refund-ref")

      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

      def capabilities = {}

      def settlement_grace_minutes = 5
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @now = Time.current.change(usec: 0)
      Orders::Order.where(event: @event, buyer_user: @buyer).active_checkouts.update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      build_checkout_graph
    end

    test "accepts a verified success at the grace boundary without releasing capacity" do
      payment = create_payment
      Orders::ExpireCheckout.call(now: @now)
      adapter = register_adapter(Payments::Providers::Result.success(
        provider_reference: payment.provider_reference, raw_status: "paid"
      ))

      result = ExpireSettlementGrace.call(payment: payment, now: payment.settlement_grace_expires_at)

      assert_predicate result, :success?, result.error&.message
      assert_equal 1, adapter.verify_calls.length
      assert_equal "fulfilled", @order.reload.status
      assert payment.reload.accepted?
      assert @reservation.reload.committed?
      assert_equal "applied", @redemption.reload.status
      assert_equal 0, @inventory.reload.held_count
      assert_equal 1, @inventory.reload.sold_count
    end

    test "releases unresolved processing holds and closes the order at grace expiry" do
      payment = create_payment
      Orders::ExpireCheckout.call(now: @now)
      register_adapter(Payments::Providers::Result.unknown(raw_status: "pending"))

      result = ExpireSettlementGrace.call(payment: payment, now: payment.settlement_grace_expires_at)

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", @order.reload.status
      assert_equal "checkout_expired", @order.closed_reason
      assert_equal "unknown", payment.reload.status
      assert @reservation.reload.released?
      assert_equal "released", @redemption.reload.status
      assert_equal 0, @inventory.reload.held_count
      assert_no_difference -> { Catalog::ProductInventory.find(@inventory.id).sold_count } do
        Orders::ExpireSettlementGrace.call(payment:, now: payment.settlement_grace_expires_at)
      end
    end

    test "failure verification releases immediately without accepting payment" do
      payment = create_payment
      Orders::ExpireCheckout.call(now: @now)
      register_adapter(Payments::Providers::Result.failure(
        failure_code: "declined", raw_status: "declined"
      ))

      result = ExpireSettlementGrace.call(payment:, now: payment.settlement_grace_expires_at)

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", @order.reload.status
      assert_equal "failed", payment.reload.status
      assert_nil payment.accepted_at
      assert @reservation.reload.released?
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    private

    def register_adapter(result)
      adapter = VerificationAdapter.new(result)
      Payments::Providers::Registry.register("chapa", adapter)
      adapter
    end

    def build_checkout_graph
      @order = Orders::Order.create!(order_attributes)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Grace parking",
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
        request_fingerprint: "b" * 64
      )
      @promotion = Catalog::Promotion.create!(
        event: @event,
        name: "Grace promotion",
        type: "fixed",
        fixed_amount_minor: 100,
        currency: "ETB",
        per_user_limit: 1,
        status: "active"
      )
      @promotion_code = Catalog::PromotionCode.create!(
        promotion: @promotion,
        code: "GRACE10",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "GRACE10")
      )
      @redemption = Orders::PromotionRedemption.create!(
        order: @order,
        promotion: @promotion,
        promotion_code: @promotion_code,
        user: @buyer,
        status: "reserved",
        discount_minor: 100,
        currency: "ETB",
        idempotency_key: "grace-redemption-#{@order.id}",
        expires_at: @order.expires_at
      )
      @order.update!(status: "pending_payment")
    end

    def create_payment
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
        provider_reference: "grace-ref-#{SecureRandom.hex(4)}",
        idempotency_key: "grace-payment-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
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
