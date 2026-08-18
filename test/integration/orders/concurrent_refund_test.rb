# frozen_string_literal: true

require "test_helper"

module Orders
  class ConcurrentRefundTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @product = Catalog::EventProduct.create!(
        event: @event, name: "Concurrent refund product #{SecureRandom.hex(4)}",
        type: "merchandise", status: "active"
      )
      @order = create_order
      @item = Orders::OrderItem.create!(
        order: @order, event_product: @product, name_snapshot: @product.name,
        type_snapshot: "merchandise", quantity: 1, base_currency: "ETB",
        base_unit_amount_minor: 1_000, charge_currency: "ETB", charge_unit_amount_minor: 1_000,
        exchange_rate: 1, discount_minor: 0, total_minor: 1_000, fulfillment_status: "fulfilled"
      )
      @order.update!(status: "fulfilled", paid_at: Time.current)
      @payment = Orders::Payment.create!(
        order: @order, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 1_000, currency: "ETB",
        commercial_signature: @order.commercial_signature, buyer_fee_minor: 0,
        organizer_fee_minor: 0, idempotency_key: "concurrent-payment-#{SecureRandom.hex(6)}",
        provider_reference: "concurrent-provider-#{SecureRandom.hex(4)}", accepted_at: Time.current,
        settlement_grace_minutes: 5, settlement_grace_expires_at: @order.expires_at + 5.minutes
      )
    end

    teardown do
      cleanup_refunds
      Orders::Payment.where(id: @payment.id).delete_all if @payment&.persisted?
      @order.update_columns(status: "draft", paid_at: nil) if @order&.persisted?
      Orders::OrderItem.where(id: @item.id).delete_all if @item&.persisted?
      Orders::Order.where(id: @order.id).delete_all if @order&.persisted?
      Catalog::EventProduct.where(id: @product.id).delete_all if @product&.persisted?
    end

    test "concurrent item refunds cannot exceed the original item value" do
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          Orders::ApplicationRecord.connection_pool.with_connection do
            Orders::CreateItemRefund.call(
              payment: Orders::Payment.find(@payment.id),
              order_item: Orders::OrderItem.find(@item.id), quantity: 1,
              reason_code: "event_cancellation", idempotency_key: "concurrent-refund-#{index}"
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.count(&:success?)
      assert_equal 1, results.count(&:failure?)
      assert_equal "refund_item_value_exceeded", results.find(&:failure?).error.code
      assert_equal 1, Orders::Refund.where(payment: @payment).count
      assert_equal 1_000, Orders::Refund.where(payment: @payment).sum(:amount_minor)
      assert_equal 1, Orders::RefundItem.where(order_item: @item).count
    ensure
      threads&.each(&:join)
    end

    private

    def cleanup_refunds
      return unless @payment&.persisted?

      connection = Orders::ApplicationRecord.connection
      disabled_triggers = {
        "orders_refunds" => %w[trg_orders_refund_reconcile],
        "orders_refund_items" => %w[trg_orders_refund_item_reconcile trg_orders_refund_item_immutable],
        "orders_refund_adjustment_allocations" => %w[
          trg_orders_refund_adjustment_reconcile trg_orders_refund_adjustment_allocation_immutable
        ]
      }
      disabled_triggers.each do |table, triggers|
        triggers.each { |trigger| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }
      end

      refund_ids = Orders::Refund.where(payment_id: @payment.id).pluck(:id)
      refund_item_ids = Orders::RefundItem.where(refund_id: refund_ids).pluck(:id)
      Orders::RefundAdjustmentAllocation.where(refund_item_id: refund_item_ids).delete_all
      Orders::RefundItem.where(id: refund_item_ids).delete_all
      Orders::Refund.where(id: refund_ids).delete_all
    ensure
      disabled_triggers&.each do |table, triggers|
        triggers.each { |trigger| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
      end
    end

    def create_order
      Orders::Order.create!(
        event: @event, buyer_user: @buyer, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: 1_000, discount_minor: 0, subsidy_minor: 0, fee_minor: 0,
        tax_minor: 0, adjustment_minor: 0, total_minor: 1_000,
        settlement_currency: "ETB", settlement_total_minor: 1_000, exchange_rate: 1,
        exchange_rate_source: "same_currency", exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now, idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
    end
  end
end
