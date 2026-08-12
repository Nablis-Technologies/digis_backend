# frozen_string_literal: true

module Commercial
  module Subsidies
    # Moves a held subsidy reservation into payment processing. Capacity stays
    # reserved until Commit or Release; the command is a state-based replay.
    class MarkProcessing < Core::BaseService
      include Support

      def initialize(reservation:, expires_at: nil, at: Time.current)
        @reservation = reservation
        @expires_at = expires_at
        @now = at.to_time.utc
      end

      def call
        ActiveRecord::Base.transaction do
          locked_reservation, = lock_reservation!(@reservation)
          if locked_reservation.processing?
            locked_reservation.update!(expires_at:) if expires_at.present? && locked_reservation.expires_at < expires_at
            return success(locked_reservation)
          end
          return failure(state_conflict) unless locked_reservation.held?
          if locked_reservation.expires_at <= now
            return failure(expired_error) unless expires_at.present? && expires_at > now
          end

          locked_reservation.update!(status: "processing", expires_at: expires_at || locked_reservation.expires_at)
          record_subsidy_transition!(
            reservation: locked_reservation,
            from: "held",
            to: "processing",
            action: "commercial.subsidy_reservation.processing",
            audit_key: reservation_transition_audit_key(locked_reservation, "processing"),
            timestamp_attribute: nil
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

      attr_reader :reservation, :expires_at, :now

      def state_conflict
        subsidy_error("state_conflict", code: "subsidy_state_conflict")
      end

      def expired_error
        subsidy_error("reservation_expired", code: "subsidy_reservation_expired")
      end
    end
  end
end
