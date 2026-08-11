# frozen_string_literal: true

require "test_helper"

module Commercial
  module Subsidies
    class CommitTest < ActiveSupport::TestCase
      include Commercial::SubsidyReservationTestHelpers

      setup do
        setup_subsidy_reservation_context
        result = Hold.call(
          budget: @budget,
          order: @order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 10.minutes.from_now,
          idempotency_key: "commit-hold"
        )
        assert_predicate result, :success?, result.error&.message
        @reservation = result.value
      end

      test "commits held capacity and moves it from reserved to consumed" do
        result = Commit.call(reservation: @reservation)

        assert_predicate result, :success?, result.error&.message
        committed = result.value.reload
        assert committed.committed?
        assert committed.committed_at
        assert_equal 0, @budget.reload.reserved_minor
        assert_equal 500, @budget.consumed_minor
      end

      test "commits processing capacity and is idempotent" do
        processing = MarkProcessing.call(reservation: @reservation)
        assert_predicate processing, :success?, processing.error&.message

        subject = -> { Commit.call(reservation: @reservation) }

        assert_audit_idempotent(
          subject,
          action: "commercial.subsidy_reservation.committed",
          auditable_type: "Commercial::SubsidyReservation",
          auditable_id: @reservation.id
        )
        assert @reservation.reload.committed?
        assert_equal 500, @budget.reload.consumed_minor
      end

      test "does not release a committed reservation" do
        result = Commit.call(reservation: @reservation)
        assert_predicate result, :success?, result.error&.message

        release = Release.call(reservation: @reservation)

        assert_predicate release, :failure?
        assert_equal "subsidy_state_conflict", release.error.code
        assert @reservation.reload.committed?
        assert_equal 500, @budget.reload.consumed_minor
      end
    end
  end
end
