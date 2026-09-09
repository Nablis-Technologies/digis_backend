# frozen_string_literal: true

module Messaging
  module Providers
    # Provider boundary for one notification channel. Implementations must
    # honor the supplied idempotency key and return DeliveryResult only.
    class Adapter
      def deliver(notification:, delivery:, content:, idempotency_key:)
        raise NotImplementedError, I18n.t("messaging.errors.adapter_not_implemented")
      end

      def deliver_campaign(campaign:, delivery:, content:, idempotency_key:)
        raise NotImplementedError, I18n.t("messaging.errors.adapter_not_implemented")
      end

      def deliver_sms(phone:, body:, idempotency_key:)
        raise NotImplementedError, I18n.t("messaging.errors.adapter_not_implemented")
      end

      def deliver_email(to:, subject:, body:, idempotency_key:)
        raise NotImplementedError, I18n.t("messaging.errors.adapter_not_implemented")
      end
    end
  end
end
