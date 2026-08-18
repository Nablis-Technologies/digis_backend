# frozen_string_literal: true

require "test_helper"

module Commercial
  module Subsidies
    class MarkProcessingTest < ActiveSupport::TestCase
      include Commercial::SubsidyReservationTestHelpers

      setup do
        setup_subsidy_reservation_context
        result = Hold.call(
          budget: @budget,
          order: @order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 10.minutes.from_now,
          idempotency_key: "processing-hold"
        )
        assert_predicate result, :success?, result.error&.message
        @reservation = result.value
      end

      test "moves a held reservation to processing without changing counters" do
        result = MarkProcessing.call(reservation: @reservation)

        assert_predicate result, :success?, result.error&.message
        assert result.value.reload.processing?
        assert_equal 500, @budget.reload.reserved_minor
        assert_equal 0, @budget.consumed_minor
      end

      test "processing replay is idempotent" do
        subject = -> { MarkProcessing.call(reservation: @reservation) }

        assert_audit_idempotent(
          subject,
          action: "commercial.subsidy_reservation.processing",
          auditable_type: "Commercial::SubsidyReservation",
          auditable_id: @reservation.id
        )
        assert @reservation.reload.processing?
      end

      test "does not move terminal reservations back into processing" do
        @reservation.update!(status: "released", released_at: Time.current)
        result = MarkProcessing.call(reservation: @reservation)

        assert_predicate result, :failure?
        assert_equal "subsidy_state_conflict", result.error.code
        assert @reservation.reload.released?
      end
    end
  end
end
