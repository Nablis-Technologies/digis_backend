# frozen_string_literal: true

module Marketplace
  module PayoutProviders
    Result = Finance::PayoutProviders::Result

    # Defines the seller payout provider boundary. Direct beneficiary values
    # stay inside command-to-provider calls and never cross serializers.
    class Adapter
      REQUIRED_METHODS = %i[
        payout verify_payout available_balance capabilities
      ].freeze

      REQUIRED_METHODS.each do |method_name|
        define_method(method_name) do |**_arguments|
          fail NotImplementedError, I18n.t(
            "marketplace.resale.errors.payout_provider_operation_not_implemented",
            adapter: self.class.name, operation: method_name
          )
        end
      end

      def available_banks(**)
        nil
      end

      def verify_payout_account(**)
        Result.unknown(raw_status: "unsupported")
      end

      private

      def normalize_result(response)
        Result.from_provider_response(response)
      rescue ArgumentError, NoMethodError, TypeError
        fail ArgumentError, I18n.t("marketplace.resale.errors.seller_payout_provider_result_invalid")
      end
    end
  end
end
