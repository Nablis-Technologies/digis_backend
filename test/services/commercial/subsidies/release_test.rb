# frozen_string_literal: true

require "test_helper"

module Commercial
  module Subsidies
    class ReleaseTest < ActiveSupport::TestCase
      include Commercial::SubsidyReservationTestHelpers

      setup do
        setup_subsidy_reservation_context
        result = Hold.call(
          budget: @budget,
          order: @order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 10.minutes.from_now,
          idempotency_key: "release-hold"
        )
        assert_predicate result, :success?, result.error&.message
        @reservation = result.value
      end

      test "releases held capacity and retains the terminal reservation" do
        result = Release.call(reservation: @reservation)

        assert_predicate result, :success?, result.error&.message
        released = result.value.reload
        assert released.released?
        assert released.released_at
        assert_equal 0, @budget.reload.reserved_minor
        assert_equal 0, @budget.consumed_minor
        assert SubsidyReservation.exists?(released.id)
      end

      test "releases processing capacity and is idempotent" do
        processing = MarkProcessing.call(reservation: @reservation)
        assert_predicate processing, :success?, processing.error&.message

        subject = -> { Release.call(reservation: @reservation) }

        assert_audit_idempotent(
          subject,
          action: "commercial.subsidy_reservation.released",
          auditable_type: "Commercial::SubsidyReservation",
          auditable_id: @reservation.id
        )
        assert @reservation.reload.released?
        assert_equal 0, @budget.reload.reserved_minor
      end

      test "does not release an already committed subsidy" do
        committed = Commit.call(reservation: @reservation)
        assert_predicate committed, :success?, committed.error&.message

        result = Release.call(reservation: @reservation)

        assert_predicate result, :failure?
        assert_equal "subsidy_state_conflict", result.error.code
        assert @reservation.reload.committed?
        assert_equal 500, @budget.reload.consumed_minor
      end
    end
  end
end
