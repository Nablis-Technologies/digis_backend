# frozen_string_literal: true

module Messaging
  module Providers
    # Inbound provider boundary for opt-out webhooks. Adapters verify raw bytes
    # before parsing and return a small provider-neutral event hash.
    class InboundAdapter
      DEFAULT_STOP_WORDS = %w[stop unsubscribe cancel quit end].freeze

      def verify_inbound(raw_body:, headers:)
        raise NotImplementedError, I18n.t("messaging.errors.inbound_adapter_not_implemented")
      end

      def parse_inbound(raw_body:, headers:)
        raise NotImplementedError, I18n.t("messaging.errors.inbound_adapter_not_implemented")
      end

      def stop_words
        DEFAULT_STOP_WORDS
      end
    end
  end
end
