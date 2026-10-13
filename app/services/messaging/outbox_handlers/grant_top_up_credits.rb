# frozen_string_literal: true

module Messaging
  module OutboxHandlers
    # Resolves an accepted billing outbox event into the Messaging credit grant
    # command. It raises command failures for Dispatch to retry and translates
    # malformed or missing source rows into a typed mismatch error.
    class GrantTopUpCredits < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        payload = @event.payload
        source_type = payload["source_type"]
        return failure(mismatch_error) unless Orders::BillingPurchase::SOURCE_TYPES.include?(source_type)
        return success(nil) unless source_type == "Messaging::CreditTopUp"

        top_up = CreditTopUp.find(payload.fetch("source_id"))
        payment = Orders::Payment.find(payload.fetch("payment_id"))
        result = Messaging::GrantTopUpCredits.call(top_up:, payment:)
        raise result.error if result.failure?

        result
      rescue KeyError, ActiveRecord::RecordNotFound => exception
        failure(Core::BusinessError.new(exception.message, code: "top_up_payment_mismatch", status: :conflict))
      end

      private

      def mismatch_error
        Core::BusinessError.new(
          I18n.t("messaging.errors.top_up_payment_mismatch"), code: "top_up_payment_mismatch", status: :conflict
        )
      end
    end
  end
end
