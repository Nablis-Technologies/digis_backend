# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Maps one provider-neutral delivery outcome to one reservation transition.
    class ApplyDeliveryResult < Core::BaseService
      include CommandSupport

      def initialize(reservation:, result:, idempotency_key:, reason: nil, at: Time.current)
        @reservation = reservation
        @result = result
        @raw_idempotency_key = idempotency_key
        @reason = reason.to_s.strip.presence
        @at = at.to_time
      end

      def call
        return failure(error(:delivery_result_invalid)) unless valid_result?
        idempotency_key
        return success(@reservation) if retryable?

        if @result == :suppressed
          resolve_reservation!(
            status: "released", entry_type: "release", available_delta: :quantity,
            resolution_code: @reason || "suppressed"
          )
        elsif @result.success?
          resolve_reservation!(
            status: "consumed", entry_type: "consume", available_delta: 0,
            resolution_code: "delivered"
          )
        else
          resolve_reservation!(
            status: "refunded", entry_type: "refund", available_delta: :quantity,
            resolution_code: @reason || failure_reason
          )
        end
      rescue ArgumentError
        failure(error(:invalid_idempotency_key))
      end

      private

      def valid_result?
        @result == :suppressed || @result.is_a?(Providers::DeliveryResult)
      end

      def retryable?
        @result.is_a?(Providers::DeliveryResult) && @result.failure? && @result.retryable
      end

      def failure_reason
        @result.failure_code || "provider_failed"
      end

      def error(key, status: :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("messaging.errors.#{key}"), code: key.to_s, status:
        )
      end
    end
  end
end
