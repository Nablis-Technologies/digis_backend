# frozen_string_literal: true

module Messaging
  module Providers
    # Resolves inbound webhook adapters without coupling Campaigns to a vendor.
    class InboundRegistry
      def self.configure(registry = nil)
        return registry if registry.is_a?(self)

        current = Rails.application.config.x.messaging_inbound_registry
        return current if current.is_a?(self)

        Rails.application.config.x.messaging_inbound_registry = new
      end

      def initialize
        @adapters = {}
      end

      def register(provider:, adapter:)
        normalized = provider.to_s.strip.downcase
        raise ArgumentError, I18n.t("messaging.errors.inbound_provider_required") if normalized.blank?
        unless adapter.respond_to?(:verify_inbound) && adapter.respond_to?(:parse_inbound)
          raise ArgumentError, I18n.t("messaging.errors.inbound_adapter_required")
        end

        @adapters[normalized] = adapter
      end

      def fetch(provider:)
        @adapters[provider.to_s.strip.downcase]
      end
    end
  end
end
