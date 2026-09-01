# frozen_string_literal: true

require "test_helper"

module Orders
  class FulfillOrderTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @manager = core_users(:super_admin)
      @product = create_ticket_product
      @order = create_order(total_minor: 0)
      @item = create_order_item
      @order.update!(status: "paid", paid_at: Time.current)
    end

    test "accepts a zero-total order without a payment and publishes fulfillment" do
      result = Orders::FulfillOrder.call(
        order: @order, payment: nil,
        idempotency_key: "free-order-fulfilled-#{@order.id}"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "fulfilled", @order.reload.status
      event = Core::OutboxEvent.find_by!(
        aggregate_id: @order.id, event_type: "orders.payment.fulfilled"
      )
      assert_nil event.payload["payment_id"]
      assert_equal [ @item.id ], event.payload.fetch("order_item_ids")
    end

    test "rejects a non-zero order without a payment" do
      order = create_order(total_minor: 1_000, status: "paid")

      result = Orders::FulfillOrder.call(order:, payment: nil)

      assert_predicate result, :failure?
      assert_equal "order_not_paid", result.error.code
      assert_equal "paid", order.reload.status
      assert_empty Core::OutboxEvent.where(aggregate_id: order.id, event_type: "orders.payment.fulfilled")
    end

    test "replaying a free fulfillment does not publish a second handoff" do
      key = "free-order-replay-#{@order.id}"
      first = Orders::FulfillOrder.call(order: @order, payment: nil, idempotency_key: key)
      second = Orders::FulfillOrder.call(order: @order, payment: nil, idempotency_key: key)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_id: @order.id, event_type: "orders.payment.fulfilled"
      ).count
    end

    private

    def create_ticket_product
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @manager,
        product_attributes: { name: "Free order ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        price_attributes: {
          type: "base", currency: "ETB", amount_minor: 0, active_from: 1.hour.ago
        },
        inventory_configuration: { mode: "unlimited" },
        idempotency_key: "free-order-product-#{SecureRandom.hex(4)}"
      ).value
      event_date = @event.event_dates.create!(
        starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, status: "scheduled"
      )
      product.product_accesses.create!(event_date:, type: "venue", usage_limit: 1)
      Catalog::Products::Activate.call(product:, actor: @manager).value
    end

    def create_order(total_minor:, status: "draft")
      Orders::Order.create!(
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status:,
        paid_at: status == "paid" ? Time.current : nil,
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: total_minor,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor:,
        settlement_currency: "ETB",
        settlement_total_minor: total_minor,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        expires_at: 1.hour.from_now,
        idempotency_key_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
        creation_request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid)
      )
    end

    def create_order_item
      Orders::OrderItem.create!(
        order: @order,
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 0,
        charge_currency: "ETB",
        charge_unit_amount_minor: 0,
        discount_minor: 0,
        total_minor: 0,
        fulfillment_status: "pending"
      )
    end
  end
end
