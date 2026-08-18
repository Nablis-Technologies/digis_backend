# frozen_string_literal: true

module Commercial
  module Subsidies
    # Returns a held or processing subsidy amount to its budget. Release is a
    # compensating transition; committed financial consumption is irreversible.
    class Release < Core::BaseService
      include Support

      def initialize(reservation:)
        @reservation = reservation
      end

      def call
        ActiveRecord::Base.transaction do
          locked_reservation, locked_budget = lock_reservation!(@reservation)
          return success(locked_reservation) if locked_reservation.released?
          return failure(state_conflict) unless locked_reservation.active?
          return failure(counter_drift) if locked_budget.reserved_minor < locked_reservation.amount_minor

          from = locked_reservation.status
          locked_budget.update!(reserved_minor: locked_budget.reserved_minor - locked_reservation.amount_minor)
          locked_reservation.update!(status: "released", released_at: Time.current)
          record_subsidy_transition!(
            reservation: locked_reservation,
            from:,
            to: "released",
            action: "commercial.subsidy_reservation.released",
            audit_key: reservation_transition_audit_key(locked_reservation, "released"),
            timestamp_attribute: :released_at
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

      def counter_drift
        subsidy_error("counter_drift", code: "subsidy_budget_counter_drift")
      end
    end
  end
end
