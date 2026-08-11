# frozen_string_literal: true

require "test_helper"

module Orders
  class LargestRemainderAllocatorTest < ActiveSupport::TestCase
    test "allocates every minor unit using exact basis-point shares" do
      result = Orders::LargestRemainderAllocator.call(
        total_minor: 10,
        allocations: [
          { id: "date-c", allocation_basis_points: 3_333 },
          { id: "date-a", allocation_basis_points: 3_333 },
          { id: "date-b", allocation_basis_points: 3_334 }
        ]
      )

      assert_predicate result, :success?
      assert_equal(
        [ [ "date-a", 3 ], [ "date-b", 4 ], [ "date-c", 3 ] ],
        result.value.map { |allocation| [ allocation.id, allocation.amount_minor ] }
      )
      assert_equal 10, result.value.sum(&:amount_minor)
    end

    test "breaks equal remainders by ascending stable id" do
      result = Orders::LargestRemainderAllocator.call(
        total_minor: 2,
        allocations: [
          { id: "date-c", allocation_basis_points: 3_333 },
          { id: "date-b", allocation_basis_points: 3_333 },
          { id: "date-a", allocation_basis_points: 3_334 }
        ]
      )

      assert_predicate result, :success?
      assert_equal(
        [ [ "date-a", 1 ], [ "date-b", 1 ], [ "date-c", 0 ] ],
        result.value.map { |allocation| [ allocation.id, allocation.amount_minor ] }
      )
    end

    test "rejects negative totals, invalid shares, duplicate ids, and incomplete shares" do
      invalid_inputs = [
        { total_minor: -1, allocations: [ { id: "date-a", allocation_basis_points: 10_000 } ] },
        { total_minor: 1, allocations: [ { id: "date-a", allocation_basis_points: 0 } ] },
        {
          total_minor: 1,
          allocations: [
            { id: "date-a", allocation_basis_points: 5_000 },
            { id: "date-a", allocation_basis_points: 5_000 }
          ]
        },
        { total_minor: 1, allocations: [ { id: "date-a", allocation_basis_points: 9_999 } ] }
      ]

      invalid_inputs.each do |attributes|
        assert_raises(ArgumentError) { Orders::LargestRemainderAllocator.call(**attributes) }
      end
    end
  end
end
