# frozen_string_literal: true

module Messaging
  module Providers
    # Provider-neutral outcome used by delivery commands so vendor response
    # bodies and credentials never become application state.
    class DeliveryResult
      STATUSES = %w[sent delivered failed].freeze
      attr_reader :status, :provider, :provider_message_id, :retryable,
                  :failure_code, :failure_detail

      def initialize(status:, provider:, provider_message_id: nil, retryable: false,
        failure_code: nil, failure_detail: nil)
        @status = status.to_s
        @provider = provider.to_s.presence
        @provider_message_id = provider_message_id.to_s.presence
        @retryable = retryable == true
        @failure_code = failure_code.to_s.presence
        @failure_detail = failure_detail.to_s.presence
        freeze
      end

      def self.delivered(provider:, provider_message_id: nil)
        new(status: "delivered", provider:, provider_message_id:)
      end

      def self.sent(provider:, provider_message_id: nil)
        new(status: "sent", provider:, provider_message_id:)
      end

      def self.failed(provider:, failure_code:, failure_detail: nil)
        new(status: "failed", provider:, failure_code:, failure_detail:)
      end

      def self.retryable(provider:, failure_code:, failure_detail: nil)
        new(status: "failed", provider:, retryable: true, failure_code:, failure_detail:)
      end

      def success?
        status.in?(%w[sent delivered])
      end

      def failure?
        !success?
      end
    end
  end
end
