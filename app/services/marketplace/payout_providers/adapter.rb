# frozen_string_literal: true

module Marketplace
  module PayoutProviders
    Result = Finance::PayoutProviders::Result

    # Defines the seller-destination and payout provider boundary. Raw
    # destination details are accepted only for tokenization; commands retain
    # the provider token and encrypted display values, never the credentials.
    class Adapter
      REQUIRED_METHODS = %i[
        tokenize_payout_account verify_payout_account payout verify_payout available_balance capabilities
      ].freeze

      REQUIRED_METHODS.each do |method_name|
        define_method(method_name) do |**_arguments|
          fail NotImplementedError, I18n.t(
            "marketplace.resale.errors.payout_provider_operation_not_implemented",
            adapter: self.class.name, operation: method_name
          )
        end
      end

      private

      def normalize_result(response)
        Result.from_provider_response(response)
      rescue ArgumentError, NoMethodError, TypeError
        fail ArgumentError, I18n.t("marketplace.resale.errors.seller_payout_provider_result_invalid")
      end

      def normalize_tokenization(response)
        attributes = response.to_h.deep_symbolize_keys
        {
          account_token: attributes[:account_token] || attributes[:token]
        }
      rescue NoMethodError, TypeError
        fail ArgumentError, I18n.t("marketplace.resale.errors.payout_account_token_invalid")
      end
    end
  end
end
