# frozen_string_literal: true

require "test_helper"

module Orders
  class AllocateDateValueTest < ActiveSupport::TestCase
    test "allocates subtotal and signed adjustment using unequal date weights" do
      result = AllocateDateValue.call(
        subtotal_minor: 10_000,
        adjustment_minor: 400,
        currency: "ETB",
        date_allocations: [
          { event_date_id: "date-c", allocation_basis_points: 2_500 },
          { event_date_id: "date-a", allocation_basis_points: 5_000 },
          { event_date_id: "date-b", allocation_basis_points: 2_500 }
        ]
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal(
        {
          "date-a" => [ 5_000, 200, 5_200 ],
          "date-b" => [ 2_500, 100, 2_600 ],
          "date-c" => [ 2_500, 100, 2_600 ]
        },
        result.value.to_h { |allocation| [ allocation.event_date_id, allocation.refund_amount.to_h.values_at(
          :subtotal_minor, :adjustment_minor, :amount_minor
        ) ] }
      )
    end

    test "allocates negative discount shares and breaks ties by stable date id" do
      result = AllocateDateValue.call(
        subtotal_minor: 10_001,
        adjustment_minor: -1,
        currency: "ETB",
        date_allocations: [
          { event_date_id: "date-b", allocation_basis_points: 5_000 },
          { event_date_id: "date-a", allocation_basis_points: 5_000 }
        ]
      )

      assert_predicate result, :success?, result.error&.message
      values = result.value.index_by(&:event_date_id)
      assert_equal [ 5_001, -1, 5_000 ], values.fetch("date-a").refund_amount.to_h.values_at(
        :subtotal_minor, :adjustment_minor, :amount_minor
      )
      assert_equal [ 5_000, 0, 5_000 ], values.fetch("date-b").refund_amount.to_h.values_at(
        :subtotal_minor, :adjustment_minor, :amount_minor
      )
    end

    test "refunding every date reconciles exactly to the original eligible value" do
      result = AllocateDateValue.call(
        subtotal_minor: 12_345,
        adjustment_minor: -345,
        currency: "ETB",
        date_allocations: [
          { event_date_id: "date-a", allocation_basis_points: 5_000 },
          { event_date_id: "date-b", allocation_basis_points: 3_000 },
          { event_date_id: "date-c", allocation_basis_points: 2_000 }
        ]
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 12_345, result.value.sum { |allocation| allocation.refund_amount.subtotal_minor }
      assert_equal(-345, result.value.sum { |allocation| allocation.refund_amount.adjustment_minor })
      assert_equal 12_000, result.value.sum { |allocation| allocation.refund_amount.amount_minor }
    end

    test "rejects incomplete date shares" do
      error = assert_raises(ArgumentError) do
        AllocateDateValue.call(
          subtotal_minor: 100,
          adjustment_minor: 0,
          currency: "ETB",
          date_allocations: [ { event_date_id: "date-a", allocation_basis_points: 9_999 } ]
        )
      end

      assert_match(/10,000|10000|basis/i, error.message)
    end
  end
end
