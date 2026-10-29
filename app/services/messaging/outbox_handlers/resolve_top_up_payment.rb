# frozen_string_literal: true

module Messaging
  module OutboxHandlers
    # Applies failed or reversed billing evidence to a top-up. The handler only
    # resolves persisted IDs from the outbox, keeping provider payloads out of
    # the credit ledger and leaving retry ownership with the outbox dispatcher.
    class ResolveTopUpPayment < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        payload = @event.payload
        source_type = payload["source_type"]
        return success(nil) if other_known_source?(source_type)

        validate_source_type!(payload)
        top_up = resolve_top_up(payload)
        payment = Orders::Payment.find(payload.fetch("payment_id"))
        outcome = @event.event_type.ends_with?("reversed") ? "reversed" : "failed"
        result = Messaging::ResolveTopUpPayment.call(top_up:, payment:, outcome:)
        raise result.error if result.failure?

        result
      rescue KeyError, ActiveRecord::RecordNotFound => exception
        failure(Core::BusinessError.new(exception.message, code: "top_up_payment_mismatch", status: :conflict))
      end

      private

      def other_known_source?(source_type)
        source_type.present? && source_type != "Messaging::CreditTopUp" &&
          Orders::BillingPurchase::SOURCE_TYPES.include?(source_type)
      end

      def validate_source_type!(payload)
        return if payload["source_type"].blank? || payload["source_type"] == "Messaging::CreditTopUp"

        raise KeyError, I18n.t("messaging.errors.top_up_payment_mismatch")
      end

      def resolve_top_up(payload)
        return CreditTopUp.find(payload["source_id"]) if payload["source_id"].present?
        return CreditTopUp.find_by!(orders_billing_purchase_id: payload["billing_purchase_id"]) if payload["billing_purchase_id"].present?

        raise KeyError, I18n.t("messaging.errors.top_up_payment_mismatch")
      end
    end
  end
end
