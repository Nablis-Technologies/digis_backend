# frozen_string_literal: true

module Messaging
  module Providers
    # Deterministic preview transport. It simulates vendor outcomes while
    # never sending a message or retaining content by default. Private Render
    # previews may opt into body logging for frontend smoke tests.
    class PreviewAdapter < Adapter
      OUTCOMES = %w[delivered sent failed retryable].freeze

      def initialize(outcome: "delivered", provider: "preview")
        @outcome = outcome.to_s.strip.downcase
        @provider = provider.to_s.strip.presence || "preview"
        return if OUTCOMES.include?(@outcome)

        raise ArgumentError, I18n.t(
          "messaging.errors.preview_provider_outcome_invalid", outcome: @outcome.inspect
        )
      end

      def deliver(**_arguments)
        result
      end

      def deliver_campaign(**_arguments)
        result
      end

      def deliver_sms(phone:, body:, **_arguments)
        Rails.logger.warn("[PREVIEW SMS] body=#{body}") if preview_debug_logging?
        result
      end

      def deliver_email(to:, subject:, body:, **_arguments)
        Rails.logger.warn("[PREVIEW EMAIL] subject=#{subject} body=#{body}") if preview_debug_logging?
        result
      end

      private

      def preview_debug_logging?
        ENV["RENDER_PREVIEW"] == "true" && ENV["DIGIS_PREVIEW_DEBUG_LOGGING"] == "true"
      end

      def result
        case @outcome
        when "delivered"
          DeliveryResult.delivered(provider: @provider)
        when "sent"
          DeliveryResult.sent(provider: @provider)
        when "failed"
          DeliveryResult.failed(provider: @provider, failure_code: "preview_failure")
        when "retryable"
          DeliveryResult.retryable(provider: @provider, failure_code: "preview_retryable")
        end
      end
    end
  end
end
