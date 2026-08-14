# frozen_string_literal: true

require "test_helper"

module Orders
  class AllocateRefundAdjustmentsTest < ActiveSupport::TestCase
    test "allocates order-level refundable adjustments proportionally across item values" do
      result = AllocateRefundAdjustments.call(
        items: [
          { id: "item-b", subtotal_minor: 2_000 },
          { id: "item-a", subtotal_minor: 1_000 }
        ],
        adjustments: [
          adjustment("order-discount", amount_minor: -300),
          adjustment("order-fee", amount_minor: 150, type: "tax")
        ]
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal(
        [
          [ "item-a", "order-discount", -100 ],
          [ "item-a", "order-fee", 50 ],
          [ "item-b", "order-discount", -200 ],
          [ "item-b", "order-fee", 100 ]
        ],
        result.value.map { |allocation| allocation.to_h.values_at(:order_item_id, :order_adjustment_id, :amount_minor) }
      )
    end

    test "keeps item-scoped adjustments on their item and excludes nonrefundable adjustments" do
      result = AllocateRefundAdjustments.call(
        items: [
          { id: "item-a", subtotal_minor: 1_000 },
          { id: "item-b", subtotal_minor: 1_000 }
        ],
        adjustments: [
          adjustment("item-a-fee", order_item_id: "item-a", amount_minor: 75, type: "service_fee"),
          adjustment("order-nonrefundable", amount_minor: 200, type: "tax", refund_policy: "nonrefundable"),
          adjustment("organizer-fee", amount_minor: 300, charged_to: "organizer", type: "service_fee")
        ]
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal(
        [ [ "item-a", "item-a-fee", 75 ] ],
        result.value.map { |allocation| allocation.to_h.values_at(:order_item_id, :order_adjustment_id, :amount_minor) }
      )
    end

    test "uses stable item ids to break equal largest-remainder ties for signed shares" do
      result = AllocateRefundAdjustments.call(
        items: [
          { id: "item-b", subtotal_minor: 1 },
          { id: "item-a", subtotal_minor: 1 }
        ],
        adjustments: [ adjustment("discount", amount_minor: -1) ]
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal [ [ "item-a", -1 ] ],
        result.value.map { |allocation| [ allocation.order_item_id, allocation.amount_minor ] }
    end

    test "rejects an order-level adjustment when no eligible item can receive it" do
      error = assert_raises(ArgumentError) do
        AllocateRefundAdjustments.call(
          items: [],
          adjustments: [ adjustment("discount", amount_minor: -1) ]
        )
      end

      assert_match(/eligible item/i, error.message)
    end

    private

    def adjustment(id, order_item_id: nil, amount_minor:, type: "discount", charged_to: "buyer",
                   refund_policy: "refundable")
      {
        id:,
        order_item_id:,
        amount_minor:,
        type:,
        charged_to:,
        refund_policy:
      }
    end
  end
end
