# frozen_string_literal: true

module Finance
  module OutboxHandlers
    class PlatformBillingPaymentAccepted < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        payload = event.payload
        source_type = payload["source_type"]
        if source_type != "Marketing::FeaturedPlacement"
          return success(nil) if Orders::BillingPurchase::SOURCE_TYPES.include?(source_type)

          return failure(Core::BusinessError.new(
            I18n.t("finance.platform_billing_entries.errors.invalid_source"),
            code: "invalid_source", status: :conflict
          ))
        end

        payment = Orders::Payment.find(payload.fetch("payment_id"))
        purchase = Orders::BillingPurchase.find(payload.fetch("billing_purchase_id"))
        result = Finance::PostPlatformBillingEntry.call(payment:, billing_purchase: purchase, type: :charge)
        raise result.error if result.failure?

        result
      rescue KeyError, ActiveRecord::RecordNotFound => exception
        failure(Core::BusinessError.new(exception.message, code: "platform_billing_source_missing", status: :conflict))
      end

      private

      attr_reader :event
    end
  end
end
