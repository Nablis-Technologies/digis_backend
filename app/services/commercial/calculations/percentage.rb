# frozen_string_literal: true

module Commercial
  module Calculations
    # Calculates a basis-point percentage over one named trusted basis and
    # applies the component's currency-specific lower/upper bounds afterward.
    class Percentage < Base
      private

      def calculate_amount
        clamp(percentage_amount)
      end

      def configuration_error_code
        return "basis_unavailable" if basis_minor.nil?
        return "basis_unavailable" if rate_bps.nil?

        nil
      end
    end
  end
end
