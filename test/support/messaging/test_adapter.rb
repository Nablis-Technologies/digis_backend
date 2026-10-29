# frozen_string_literal: true

module Messaging
  module Providers
    # Deterministic provider double for tests. It exercises the same adapter
    # boundary as an external SMS or email vendor without persisting content,
    # credentials, or provider payloads.
    class TestAdapter < Adapter
      DEFAULT_PROVIDER = "test"

      attr_reader :calls

      def initialize(default: DeliveryResult.delivered(provider: DEFAULT_PROVIDER), outcomes: {}, provider: DEFAULT_PROVIDER, &resolver)
        @default = default
        @outcomes = outcomes
        @provider = provider
        @resolver = resolver
        @calls = []
      end

      def deliver(delivery:, **_arguments)
        deliver_result(delivery)
      end

      def deliver_campaign(delivery:, **_arguments)
        deliver_result(delivery)
      end

      private

      def deliver_result(delivery)
        @calls << { delivery_id: delivery.id, channel: delivery.channel }
        configured = @resolver ? @resolver.call(delivery) : @outcomes.fetch(delivery.id, @default)
        return configured if configured.is_a?(DeliveryResult)

        case configured
        when :delivered
          DeliveryResult.delivered(provider: @provider)
        when :sent
          DeliveryResult.sent(provider: @provider)
        when :failed
          DeliveryResult.failed(provider: @provider, failure_code: "test_failure")
        when :retryable
          DeliveryResult.retryable(provider: @provider, failure_code: "test_retryable")
        when :raise
          raise "test provider error"
        else
          raise ArgumentError, "Unsupported test provider outcome: #{configured.inspect}"
        end
      end
    end
  end
end
