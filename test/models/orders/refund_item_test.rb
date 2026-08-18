# frozen_string_literal: true

require "test_helper"

module Orders
  class RefundItemTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Refund item product #{SecureRandom.hex(4)}",
        type: "merchandise",
        status: "active"
      )
      @order = Orders::Order.create!(order_attributes)
      @order_item = Orders::OrderItem.create!(
        order: @order,
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: @product.type,
        quantity: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 1_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 1_000,
        discount_minor: 0,
        total_minor: 1_000,
        fulfillment_status: "fulfilled"
      )
      @order.update!(status: "pending_payment")
      @payment = Orders::Payment.create!(payment_attributes)
    end

    test "accepts an itemized refund item for the payment order" do
      refund = Orders::Refund.new(refund_attributes)
      item = Orders::RefundItem.new(
        refund:,
        order_item: @order_item,
        quantity: 1,
        subtotal_minor: 1_000,
        amount_minor: 1_000
      )

      assert_predicate refund, :valid?, refund.errors.full_messages
      assert_predicate item, :valid?, item.errors.full_messages
    end

    test "database rejects an item from another order" do
      other_order = Orders::Order.create!(order_attributes.merge(
        buyer_user: core_users(:support),
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      ))
      other_item = Orders::OrderItem.create!(
        order: other_order,
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: @product.type,
        quantity: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 1_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 1_000,
        discount_minor: 0,
        total_minor: 1_000,
        fulfillment_status: "fulfilled"
      )
      other_order.update!(status: "expired", closed_reason: "test_cleanup")
      refund = Orders::Refund.create!(refund_attributes)

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundItem.insert_all!([
          {
            id: SecureRandom.uuid,
            refund_id: refund.id,
            order_item_id: other_item.id,
            quantity: 1,
            subtotal_minor: 1_000,
            amount_minor: 1_000,
            restock: false,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end

    test "database rejects a date-scoped item without a ticket" do
      event_date = Events::EventDate.create!(
        event: @event,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 4.hours
      )
      @product.product_accesses.create!(event_date:, type: "venue")
      @product.product_date_allocations.create!(event_date:, allocation_basis_points: 10_000)
      refund = Orders::Refund.create!(refund_attributes)

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundItem.insert_all!([
          {
            id: SecureRandom.uuid,
            refund_id: refund.id,
            order_item_id: @order_item.id,
            event_date_id: event_date.id,
            quantity: 1,
            subtotal_minor: 1_000,
            amount_minor: 1_000,
            restock: false,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end

    test "database rejects items on a payment reversal" do
      refund = Orders::Refund.create!(refund_attributes(type: "payment_reversal", reason_code: "late_payment"))

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundItem.insert_all!([
          {
            id: SecureRandom.uuid,
            refund_id: refund.id,
            order_item_id: @order_item.id,
            quantity: 1,
            subtotal_minor: 1_000,
            amount_minor: 1_000,
            restock: false,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end

    test "database keeps refund items immutable" do
      refund_item = create_refund_item

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundItem.where(id: refund_item.id).update_all(amount_minor: 999)
      end
    end

    test "database prevents deleting refund items" do
      refund_item = create_refund_item

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundItem.where(id: refund_item.id).delete_all
      end
    end

    private

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 1_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 1_000,
        settlement_currency: "ETB",
        settlement_total_minor: 1_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def payment_attributes
      {
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor: 1_000,
        currency: "ETB",
        commercial_signature: @order.commercial_signature,
        idempotency_key: "payment-#{SecureRandom.hex(6)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end

    def refund_attributes(overrides = {})
      {
        payment: @payment,
        type: "item_refund",
        idempotency_key: "refund-#{SecureRandom.hex(6)}",
        amount_minor: 1_000,
        currency: "ETB",
        status: "created",
        reason_code: "event_cancellation"
      }.merge(overrides)
    end

    def create_refund_item
      refund = Orders::Refund.create!(refund_attributes)
      Orders::RefundItem.create!(
        refund:,
        order_item: @order_item,
        quantity: 1,
        subtotal_minor: 1_000,
        amount_minor: 1_000
      )
    end
  end
end
