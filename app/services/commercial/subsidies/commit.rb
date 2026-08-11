# frozen_string_literal: true

module Commercial
  module Subsidies
    # Converts a held or processing subsidy reservation into consumed budget.
    # The reservation remains as terminal evidence and the counter transfer is
    # committed atomically with its status transition.
    class Commit < Core::BaseService
      include Support

      def initialize(reservation:)
        @reservation = reservation
      end

      def call
        ActiveRecord::Base.transaction do
          locked_reservation, locked_budget = lock_reservation!(@reservation)
          return success(locked_reservation) if locked_reservation.committed?
          return failure(state_conflict) unless locked_reservation.active?
          return failure(expired_error) if locked_reservation.expires_at <= Time.current
          return failure(counter_drift) if locked_budget.reserved_minor < locked_reservation.amount_minor

          from = locked_reservation.status
          locked_budget.update!(
            reserved_minor: locked_budget.reserved_minor - locked_reservation.amount_minor,
            consumed_minor: locked_budget.consumed_minor + locked_reservation.amount_minor
          )
          locked_reservation.update!(status: "committed", committed_at: Time.current)
          record_subsidy_transition!(
            reservation: locked_reservation,
            from:,
            to: "committed",
            action: "commercial.subsidy_reservation.committed",
            audit_key: reservation_transition_audit_key(locked_reservation, "committed"),
            timestamp_attribute: :committed_at
          )
          success(locked_reservation)
        end
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(invalid_record_error(error))
      rescue ActiveRecord::RecordNotFound
        failure(subsidy_error("record_not_found", code: "subsidy_record_not_found"))
      end

      private

      attr_reader :reservation

      def state_conflict
        subsidy_error("state_conflict", code: "subsidy_state_conflict")
      end

      def expired_error
        subsidy_error("reservation_expired", code: "subsidy_reservation_expired")
      end

      def counter_drift
        subsidy_error("counter_drift", code: "subsidy_budget_counter_drift")
      end
    end
  end
end
