# frozen_string_literal: true

module Finance
  module OutboxHandlers
    class PlatformBillingRefundSucceeded < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        refund = Orders::Refund.find(event.payload.fetch("refund_id"))
        payment = Orders::Payment.find(refund.payment_id)
        return success(nil) unless payment.billing_payment?

        purchase = Orders::BillingPurchase.find(payment.billing_purchase_id)
        if purchase.source_type != "Marketing::FeaturedPlacement"
          return success(nil) if Orders::BillingPurchase::SOURCE_TYPES.include?(purchase.source_type)

          return failure(Core::BusinessError.new(
            I18n.t("finance.platform_billing_entries.errors.invalid_source"),
            code: "invalid_source", status: :conflict
          ))
        end

        result = Finance::PostPlatformBillingEntry.call(payment:, billing_purchase: purchase, refund:, type: :refund)
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
