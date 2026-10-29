# frozen_string_literal: true

module Finance
  module PayoutProviders
    # Chapa payout transport is injected just like the payment transport. The
    # adapter does not decide reserve policy or mutate payout rows.
    class ChapaAdapter < Adapter
      PROVIDER = "chapa"

      def initialize(client: nil, capabilities: {})
        @client = client
        @capabilities = capabilities.to_h.deep_symbolize_keys.freeze
      end

      def payout(**request) = delegate(:payout, **request)

      def verify_payout(**request) = delegate(:verify_payout, **request)

      def verify_payout_account(**request)
        return Result.unknown(raw_status: "unsupported") unless @client&.respond_to?(:verify_payout_account)

        delegate(:verify_payout_account, **request)
      end

      def available_banks(**request)
        return unless @client&.respond_to?(:available_banks)

        @client.public_send(:available_banks, **request)
      end

      def available_balance(**request)
        return unless @client

        @client.public_send(:available_balance, **request).to_h.deep_symbolize_keys.freeze
      end

      def capabilities = @capabilities

      private

      def delegate(operation, **request)
        return Result.unknown(raw_status: "unconfigured") unless @client

        normalize_result(@client.public_send(operation, **request))
      end
    end
  end
end
