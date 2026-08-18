# frozen_string_literal: true

module Streaming
  module Providers
    # Explicit adapter boundary for provider capability and playback material.
    # Authorization remains owned by Streaming::Authorization and session
    # lifecycle commands, never by a provider implementation.
    class BaseAdapter
      def playback_grant(session:, window:)
        fail NotImplementedError, I18n.t("streaming.errors.adapter_not_implemented", adapter: self.class.name, operation: "playback_grant")
      end

      def revoke_playback(session:)
        fail NotImplementedError, I18n.t("streaming.errors.adapter_not_implemented", adapter: self.class.name, operation: "revoke_playback")
      end

      def supported_access_protections
        fail NotImplementedError, I18n.t("streaming.errors.adapter_not_implemented", adapter: self.class.name, operation: "supported_access_protections")
      end

      def validate_configuration!(event_stream)
        return if supported_access_protections.include?(event_stream.access_protection)

        fail InvalidConfiguration, I18n.t(
          "streaming.errors.protection_not_supported",
          provider: event_stream.provider,
          protection: event_stream.access_protection
        )
      end
    end
  end
end
