# frozen_string_literal: true

require "test_helper"

module Commercial
  module Subsidies
    class ExpireHoldsTest < ActiveSupport::TestCase
      include Commercial::SubsidyReservationTestHelpers

      setup do
        setup_subsidy_reservation_context(limit_minor: 1_500)
      end

      test "expires held and processing rows and releases their budget capacity" do
        first = Hold.call(
          budget: @budget,
          order: @order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 1.minute.from_now,
          idempotency_key: "active-hold"
        )
        assert_predicate first, :success?, first.error&.message

        second_order = create_order(buyer: core_users(:support), subsidy_minor: 500)
        second = Hold.call(
          budget: @budget,
          order: second_order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 1.minute.from_now,
          idempotency_key: "processing-hold"
        )
        assert_predicate second, :success?, second.error&.message
        processing = MarkProcessing.call(reservation: second.value)
        assert_predicate processing, :success?, processing.error&.message
        count = ExpireHolds.call(now: 2.minutes.from_now)

        assert_predicate count, :success?, count.error&.message
        assert_equal 2, count.value
        assert_equal [ "released" ], SubsidyReservation.where(id: [ first.value.id, second.value.id ]).pluck(:status).uniq
        assert_equal 0, @budget.reload.reserved_minor
        assert_equal 0, @budget.consumed_minor
      end

      test "does not expire a non-expired hold or a committed reservation" do
        active = Hold.call(
          budget: @budget,
          order: @order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 10.minutes.from_now,
          idempotency_key: "future-hold"
        )
        assert_predicate active, :success?, active.error&.message

        committed_order = create_order(buyer: core_users(:support), subsidy_minor: 500)
        committed = Hold.call(
          budget: @budget,
          order: committed_order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 10.minutes.from_now,
          idempotency_key: "future-committed-hold"
        )
        assert_predicate committed, :success?, committed.error&.message
        result = Commit.call(reservation: committed.value)
        assert_predicate result, :success?, result.error&.message

        count = ExpireHolds.call(now: 1.minute.from_now)

        assert_predicate count, :success?, count.error&.message
        assert_equal 0, count.value
        assert active.value.reload.held?
        assert committed.value.reload.committed?
        assert_equal 500, @budget.reload.reserved_minor
        assert_equal 500, @budget.consumed_minor
      end
    end
  end
end
