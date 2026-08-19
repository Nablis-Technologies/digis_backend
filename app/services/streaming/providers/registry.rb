# frozen_string_literal: true

module Streaming
  module Providers
    # Allowlisted provider lookup. Test fakes are injected into commands and
    # never become production registry entries.
    class Registry
      HANDLERS = {
        "youtube" => YouTubeAdapter
      }.freeze

      def self.fetch(provider)
        key = provider.to_s
        fail UnknownProvider, I18n.t("streaming.errors.unsupported_provider", provider: key) unless HANDLERS.key?(key)
        fail UnknownProvider, I18n.t("streaming.errors.disabled_provider", provider: key) unless enabled_provider_keys.include?(key)

        HANDLERS.fetch(key).new
      end

      def self.for(event_stream)
        fetch(event_stream.provider).tap { |adapter| adapter.validate_configuration!(event_stream) }
      end

      def self.enabled_provider_keys
        Array(Rails.application.config.x.streaming.enabled_providers).map(&:to_s)
      end

      private_class_method :enabled_provider_keys
    end
  end
end
