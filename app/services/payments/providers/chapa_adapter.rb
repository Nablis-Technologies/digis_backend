# frozen_string_literal: true

module Payments
  module Providers
    # Chapa's HTTP client is injected so this adapter remains a deterministic
    # boundary in tests and does not let provider payloads or fee math leak
    # into Orders.
    class ChapaAdapter < Adapter
      PROVIDER = "chapa"

      def initialize(client: nil, capabilities: {}, settlement_grace_minutes: 5)
        @client = client
        @capabilities = deep_freeze(capabilities.to_h.deep_symbolize_keys)
        @settlement_grace_minutes = validate_grace_minutes(settlement_grace_minutes)
      end

      def create(**request) = delegate(:create, **request)

      def merchant_reference(**request)
        return unless @client&.respond_to?(:merchant_reference)

        @client.public_send(:merchant_reference, **request)
      end

      def direct_charge(**request) = delegate(:direct_charge, **request)

      def cancel(**request) = delegate(:cancel, **request)

      def verify(**request) = delegate(:verify, **request)

      def verify_webhook(**request)
        return false unless @client

        !!@client.public_send(:verify_webhook, **request)
      end

      def refund(**request) = delegate(:refund, **request)

      def verify_refund(**request) = delegate(:verify_refund, **request)

      def available_balance(**request)
        return unless @client

        @client.public_send(:available_balance, **request).to_h.deep_symbolize_keys.freeze
      end

      def capabilities = @capabilities

      def settlement_grace_minutes = @settlement_grace_minutes

      private

      def delegate(operation, **request)
        return Result.unknown(raw_status: "unconfigured") unless @client

        normalize_result(@client.public_send(operation, **request))
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
