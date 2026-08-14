# frozen_string_literal: true

require "test_helper"

module Orders
  class RefundAdjustmentAllocationTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Refund adjustment product #{SecureRandom.hex(4)}",
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
      @adjustment = Orders::OrderAdjustment.create!(adjustment_attributes)
      @organizer_adjustment = Orders::OrderAdjustment.create!(
        adjustment_attributes(charged_to: "organizer", amount_minor: 100)
      )
      @zero_adjustment = Orders::OrderAdjustment.create!(
        adjustment_attributes(
          type: "manual_adjustment",
          label: "Zero adjustment",
          amount_minor: 0,
          calculation_type: "explicit_zero",
          basis_type: nil,
          basis_minor: nil,
          rate_bps: nil,
          source_type: nil,
          source_id: nil
        )
      )
      @order.update!(status: "pending_payment")
      @payment = Orders::Payment.create!(payment_attributes)
      @refund = Orders::Refund.create!(refund_attributes)
      @refund_item = Orders::RefundItem.create!(
        refund: @refund,
        order_item: @order_item,
        quantity: 1,
        subtotal_minor: 900,
        amount_minor: 1_000
      )
    end

    test "accepts a signed buyer adjustment allocation" do
      allocation = Orders::RefundAdjustmentAllocation.new(
        refund_item: @refund_item,
        order_adjustment: @adjustment,
        amount_minor: 100
      )

      assert_predicate allocation, :valid?, allocation.errors.full_messages
    end

    test "database rejects an adjustment from another order" do
      other_order = Orders::Order.create!(order_attributes.merge(
        buyer_user: core_users(:support),
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      ))
      adjustment = Orders::OrderAdjustment.create!(
        adjustment_attributes(order: other_order, order_item: nil, amount_minor: 100)
      )
      other_order.update!(status: "expired", closed_reason: "test_cleanup")

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundAdjustmentAllocation.insert_all!([
          {
            id: SecureRandom.uuid,
            refund_item_id: @refund_item.id,
            order_adjustment_id: adjustment.id,
            amount_minor: 100,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end

    test "database rejects organizer or nonrefundable adjustment allocations" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundAdjustmentAllocation.insert_all!([
          {
            id: SecureRandom.uuid,
            refund_item_id: @refund_item.id,
            order_adjustment_id: @organizer_adjustment.id,
            amount_minor: 100,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end

    test "database rejects allocations for a zero-valued adjustment" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundAdjustmentAllocation.insert_all!([
          {
            id: SecureRandom.uuid,
            refund_item_id: @refund_item.id,
            order_adjustment_id: @zero_adjustment.id,
            amount_minor: 1,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end

    test "database keeps adjustment allocations immutable" do
      allocation = Orders::RefundAdjustmentAllocation.create!(
        refund_item: @refund_item,
        order_adjustment: @adjustment,
        amount_minor: 100
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundAdjustmentAllocation.where(id: allocation.id).update_all(amount_minor: 50)
      end
    end

    test "database prevents deleting adjustment allocations" do
      allocation = Orders::RefundAdjustmentAllocation.create!(
        refund_item: @refund_item,
        order_adjustment: @adjustment,
        amount_minor: 100
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::RefundAdjustmentAllocation.where(id: allocation.id).delete_all
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

    def refund_attributes
      {
        payment: @payment,
        type: "item_refund",
        idempotency_key: "refund-#{SecureRandom.hex(6)}",
        amount_minor: 1_000,
        currency: "ETB",
        status: "created",
        reason_code: "event_cancellation"
      }
    end

    def adjustment_attributes(overrides = {})
      {
        order: @order,
        order_item: @order_item,
        type: "service_fee",
        label: "Service fee",
        charged_to: "buyer",
        amount_minor: 100,
        currency: "ETB",
        refund_policy: "refundable",
        calculation_type: "percentage",
        basis_type: "eligible_order_subtotal",
        basis_minor: 1_000,
        rate_bps: 100,
        funded_by: "buyer",
        source_type: "Commercial::FeeComponent",
        source_id: SecureRandom.uuid
      }.merge(overrides)
    end
  end
end
