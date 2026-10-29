# frozen_string_literal: true

require "test_helper"

module Orders
  class PaymentGraceRaceTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include Finance::LedgerTestHelpers

    class RaceAdapter < Payments::Providers::Adapter
      def verify(**)
        Payments::Providers::Result.success(provider_reference: "race-reference", raw_status: "paid")
      end

      def create(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")

      def verify_webhook(**) = true

      def refund(**) = Payments::Providers::Result.success(provider_reference: "refund-reference")

      def verify_refund(**) = Payments::Providers::Result.success(provider_reference: "refund-reference")

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
      Payments::Providers::Registry.register("chapa", RaceAdapter.new)
      build_checkout_graph
      @payment = create_payment
      @event_record = create_payment_event
      result = Orders::ExpireCheckout.call(now: @now)
      assert_predicate result, :success?, result.error&.message
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
      Orders::Refund.where(payment_id: @payment.id).delete_all if @payment&.persisted?
      Orders::PaymentEvent.where(id: @event_record.id).delete_all if @event_record&.persisted?
      cleanup_payment_ledger_entries(payment_ids: @payment.id) if @payment&.persisted?
      Orders::Payment.where(id: @payment.id).delete_all if @payment&.persisted?
      @order.update_columns(status: "draft", paid_at: nil, closed_reason: nil) if @order&.persisted?
      Orders::OrderItem.where(id: @item.id).delete_all if @item&.persisted?
      Catalog::InventoryReservation.where(id: @reservation.id).delete_all if @reservation&.persisted?
      Catalog::ProductInventory.where(id: @inventory.id).delete_all if @inventory&.persisted?
      Catalog::EventProduct.where(id: @product.id).delete_all if @product&.persisted?
      Orders::Order.where(id: @order.id).delete_all if @order&.persisted?
    end

    test "concurrent webhook and grace worker accept one success without reacquiring inventory" do
      race = run_database_race do |index|
        if index.zero?
          Orders::ProcessPaymentEvent.call(event_id: @event_record.id)
        else
          payment = Orders::Payment.find(@payment.id)
          Orders::ExpireSettlementGrace.call(payment:, now: payment.settlement_grace_expires_at)
        end
      end
      results = race.results

      assert_empty race.errors, race.errors.inspect
      assert results.all?(&:success?), results.map { |result| result.error&.message }.inspect
      assert_equal 1, Orders::Payment.where(id: @payment.id).where.not(accepted_at: nil).count
      assert_equal "fulfilled", @order.reload.status
      assert_equal 1, @inventory.reload.sold_count
      assert_equal 0, @inventory.reload.held_count
      assert_empty Orders::Refund.where(payment_id: @payment.id)
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_type: "Orders::Order",
        aggregate_id: @order.id,
        event_type: "orders.payment.fulfilled"
      ).count
    end

    private

    def build_checkout_graph
      @order = Orders::Order.create!(order_attributes)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Race parking",
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
        request_fingerprint: "c" * 64
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
        provider_reference: "race-reference",
        idempotency_key: "race-payment-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      )
    end

    def create_payment_event
      Orders::PaymentEvent.create!(
        payment: @payment,
        provider: "chapa",
        provider_event_id: "race-event-#{SecureRandom.hex(4)}",
        event_type: "payment.succeeded",
        status: "received",
        payload: { "status" => "paid", "provider_reference" => @payment.provider_reference },
        payload_digest: "d" * 64,
        received_at: @now
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
