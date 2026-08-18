# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  module Fulfillment
    class FulfillAddOnTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @buyer = core_users(:attendee)
      end

      test "fulfills each supported add-on without creating a ticket or QR credential" do
        before_ticket_count = Ticketing::Ticket.count

        Prosopite.pause do
          %w[merchandise food donation digital_addon].each do |type|
            item = create_order_item(type:)
            result = FulfillAddOn.call(order_item: item, idempotency_key: "addon:#{item.id}")

            assert_predicate result, :success?, result.error&.message
            assert_equal item.id, result.value.id
            assert_equal "fulfilled", result.value.reload.fulfillment_status
          end
        end

        assert_equal before_ticket_count, Ticketing::Ticket.count
      end

      test "retry returns the same fulfilled order item without another side effect" do
        item = create_order_item(type: "merchandise")
        key = "addon:#{item.id}"

        first = FulfillAddOn.call(order_item: item, idempotency_key: key)
        updated_at = first.value.reload.updated_at
        second = FulfillAddOn.call(order_item: item, idempotency_key: key)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal first.value.id, second.value.id
        assert_equal "fulfilled", second.value.fulfillment_status
        assert_equal updated_at, second.value.updated_at
      end

      test "does not fulfill an unpaid order item" do
        item = create_order_item(type: "food", order_status: "pending_payment")

        result = FulfillAddOn.call(order_item: item, idempotency_key: "addon:#{item.id}")

        assert_predicate result, :failure?
        assert_equal "order_not_paid", result.error.code
        assert_equal "pending", item.reload.fulfillment_status
      end

      test "does not fulfill parking or other products through the generic add-on boundary" do
        Prosopite.pause do
          %w[parking other].each do |type|
            item = create_order_item(type:)

            result = FulfillAddOn.call(order_item: item, idempotency_key: "addon:#{item.id}")

            assert_predicate result, :failure?
            assert_equal "unsupported_add_on_type", result.error.code
            assert_equal "pending", item.reload.fulfillment_status
          end
        end
      end

      test "preserves a custom donation amount already snapshotted on the order item" do
        item = create_order_item(type: "donation", amount_minor: 375, allow_custom_price: true)

        result = FulfillAddOn.call(order_item: item, idempotency_key: "addon:#{item.id}")

        assert_predicate result, :success?, result.error&.message
        assert_equal 375, result.value.reload.total_minor
      end

      test "fulfills a paid item even when its inventory is already committed" do
        item = create_order_item(type: "merchandise", inventory_capacity: 1, inventory_sold_count: 1)

        result = FulfillAddOn.call(order_item: item, idempotency_key: "addon:#{item.id}")

        assert_predicate result, :success?, result.error&.message
        assert_equal "fulfilled", result.value.reload.fulfillment_status
      end

      private

      def create_order_item(type:, order_status: "paid", amount_minor: 1_000,
        allow_custom_price: false, inventory_capacity: nil, inventory_sold_count: 0)
        product = Catalog::EventProduct.create!(
          event: @event,
          name: "#{type} #{SecureRandom.hex(4)}",
          type:,
          status: "active",
          inventory_mode: inventory_capacity ? "event_wide" : "unlimited",
          allow_custom_price:,
          schedule_change_refund_policy: "full_or_partial",
          min_per_order: 1
        )
        if inventory_capacity
          Catalog::ProductInventory.create!(
            event_product: product,
            capacity: inventory_capacity,
            held_count: 0,
            sold_count: inventory_sold_count
          )
        end

        order = Orders::Order.create!(
          event: @event,
          buyer_user: @buyer,
          sales_channel: "online",
          status: "draft",
          paid_at: nil,
          charge_currency: "ETB",
          commercial_signature: "a" * 64,
          subtotal_minor: amount_minor,
          discount_minor: 0,
          subsidy_minor: 0,
          fee_minor: 0,
          tax_minor: 0,
          adjustment_minor: 0,
          total_minor: amount_minor,
          settlement_currency: "ETB",
          settlement_total_minor: amount_minor,
          exchange_rate: 1,
          exchange_rate_source: "test",
          expires_at: 1.hour.from_now,
          idempotency_key_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
          creation_request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid)
        )

        item = order.order_items.create!(
          event_product: product,
          name_snapshot: product.name,
          type_snapshot: type,
          quantity: 1,
          admissions_per_unit_snapshot: nil,
          base_currency: "ETB",
          base_unit_amount_minor: amount_minor,
          charge_currency: "ETB",
          charge_unit_amount_minor: amount_minor,
          exchange_rate: 1,
          discount_minor: 0,
          total_minor: amount_minor,
          fulfillment_status: "pending"
        )
        order.update_columns(
          status: order_status,
          paid_at: order_status.in?(Orders::Order::PAID_STATUSES) ? Time.current : nil
        )
        item
      end
    end
  end
end
