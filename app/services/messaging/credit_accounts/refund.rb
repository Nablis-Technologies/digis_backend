# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Returns a reservation after a permanent provider failure.
    class Refund < Core::BaseService
      include CommandSupport

      def initialize(reservation:, idempotency_key:, reason:, at: Time.current)
        @reservation = reservation
        @raw_idempotency_key = idempotency_key
        @reason = reason.to_s.strip
        @at = at.to_time
      end

      def call
        return failure_result(:reason_required) if @reason.blank?

        resolve_reservation!(
          status: "refunded", entry_type: "refund", available_delta: :quantity,
          resolution_code: @reason
        )
      end
    end
  end
end
