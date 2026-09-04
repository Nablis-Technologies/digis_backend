# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Releases a pre-send reservation, such as a consent-suppressed recipient.
    class Release < Core::BaseService
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
          status: "released", entry_type: "release", available_delta: :quantity,
          resolution_code: @reason
        )
      end
    end
  end
end
