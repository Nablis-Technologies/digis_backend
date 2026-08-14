# frozen_string_literal: true

module Finance
  module PayoutProviders
    # Defines the payout provider boundary. Gateway HTTP, provider-specific
    # authentication, and response parsing stay behind this adapter so the
    # finance commands can prove durable state transitions independently.
    class Adapter
      REQUIRED_METHODS = %i[payout verify_payout available_balance capabilities].freeze

      REQUIRED_METHODS.each do |method_name|
        define_method(method_name) do |**_arguments|
          fail NotImplementedError, I18n.t(
            "finance.payout_providers.errors.adapter_operation_not_implemented",
            adapter: self.class.name, operation: method_name
          )
        end
      end

      private

      def normalize_result(response)
        Result.from_provider_response(response)
      rescue ArgumentError, NoMethodError, TypeError
        fail ArgumentError, I18n.t("finance.payout_providers.errors.invalid_result")
      end
    end
  end
end
