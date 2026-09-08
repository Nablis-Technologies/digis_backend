# frozen_string_literal: true

module Marketplace
  module PayoutProviders
    # Chapa transport for seller destinations. Provider-specific HTTP and
    # response parsing stay behind this adapter; payout commands own all
    # durable state transitions and accounting decisions.
    class ChapaAdapter < Adapter
      PROVIDER = "chapa"

      def initialize(client: nil)
        @client = client
      end

      def tokenize_payout_account(**request)
        return Result.unknown(raw_status: "unconfigured") unless @client
        raise_not_implemented!(:tokenize_payout_account) unless @client.respond_to?(:tokenize_payout_account)

        normalize_tokenization(@client.public_send(:tokenize_payout_account, **request))
      end

      def verify_payout_account(**request) = delegate(:verify_payout_account, **request)

      def payout(**request) = delegate(:payout, **request)

      def verify_payout(**request) = delegate(:verify_payout, **request)

      def available_balance(**request)
        return unless @client

        @client.public_send(:available_balance, **request).to_h.deep_symbolize_keys.freeze
      end

      def capabilities
        return {} unless @client
        return @client.public_send(:capabilities).to_h.deep_symbolize_keys.freeze if @client.respond_to?(:capabilities)

        {}.freeze
      end

      private

      def delegate(operation, **request)
        return Result.unknown(raw_status: "unconfigured") unless @client
        raise_not_implemented!(operation) unless @client.respond_to?(operation)

        normalize_result(@client.public_send(operation, **request))
      end

      def raise_not_implemented!(operation)
        raise NotImplementedError, I18n.t(
          "marketplace.resale.errors.payout_provider_operation_not_implemented",
          adapter: self.class.name, operation:
        )
      end
    end
  end
end
