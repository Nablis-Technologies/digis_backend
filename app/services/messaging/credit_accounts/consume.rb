# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Marks a successfully delivered campaign reservation as consumed.
    class Consume < Core::BaseService
      include CommandSupport

      def initialize(reservation:, idempotency_key:, at: Time.current)
        @reservation = reservation
        @raw_idempotency_key = idempotency_key
        @at = at.to_time
      end

      def call
        resolve_reservation!(
          status: "consumed", entry_type: "consume", available_delta: 0,
          resolution_code: "delivered"
        )
      end
    end
  end
end
