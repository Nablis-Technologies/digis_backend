# frozen_string_literal: true

module Payments
  module Providers
    # Defines the provider boundary without embedding gateway HTTP or fee
    # calculations in Orders. Implementations return Providers::Result for
    # payment state and expose only capability/grace metadata synchronously.
    class Adapter
      REQUIRED_METHODS = %i[
        create cancel verify verify_webhook refund verify_refund available_balance capabilities
        settlement_grace_minutes
      ].freeze

      REQUIRED_METHODS.each do |method_name|
        define_method(method_name) do |**_arguments|
          fail NotImplementedError, I18n.t(
            "payments.providers.errors.adapter_operation_not_implemented",
            adapter: self.class.name, operation: method_name
          )
        end
      end

      private

      def normalize_result(response)
        return response if response.is_a?(Result)

        Result.from_provider_response(response)
      end

      def validate_grace_minutes(value)
        return value if value.is_a?(Integer) && value.between?(3, 15)

        fail ArgumentError, I18n.t("payments.providers.errors.invalid_grace_minutes")
      end
    end
  end
end
