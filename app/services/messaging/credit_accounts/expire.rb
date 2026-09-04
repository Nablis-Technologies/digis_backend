# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Expires a reservation that has exceeded the delivery retry policy.
    class Expire < Core::BaseService
      include CommandSupport

      def initialize(reservation:, idempotency_key:, reason: "reservation_expired", at: Time.current)
        @reservation = reservation
        @raw_idempotency_key = idempotency_key
        @reason = reason.to_s.strip
        @at = at.to_time
      end

      def call
        return failure_result(:reason_required) if @reason.blank?

        resolve_reservation!(
          status: "expired", entry_type: "expire", available_delta: :quantity,
          resolution_code: @reason
        )
      end
    end
  end
end
