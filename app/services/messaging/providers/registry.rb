# frozen_string_literal: true

module Messaging
  module Providers
    # In-process channel registry. Provider configuration is deliberately kept
    # outside notification rows so credentials cannot leak through APIs.
    class Registry
      def self.configure(registry = nil)
        configured = registry.is_a?(self) ? registry : new
        configured.register(channel: "in_app", adapter: InApp.new) unless configured.fetch(channel: "in_app")
        configured
      end

      def initialize
        @adapters = {}
      end

      def register(channel:, adapter:)
        normalized = channel.to_s.strip.downcase
        raise ArgumentError, I18n.t("messaging.errors.channel_required") if normalized.blank?
        raise ArgumentError, I18n.t("messaging.errors.adapter_required") unless adapter.respond_to?(:deliver)

        @adapters[normalized] = adapter
      end

      def fetch(channel:)
        @adapters[channel.to_s.strip.downcase]
      end

      def unregister(channel:)
        @adapters.delete(channel.to_s.strip.downcase)
      end
    end
  end
end
