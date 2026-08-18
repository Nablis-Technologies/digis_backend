# frozen_string_literal: true

module Commercial
  module Calculations
    # Adds an explicit fixed amount to a rounded percentage and clamps only the
    # final sum. Keeping this order stable is part of the financial contract.
    class Blended < Base
      private

      def calculate_amount
        clamp(fixed_amount_minor + percentage_amount)
      end

      def configuration_error_code
        return "commercial_terms_unavailable" if fixed_amount_minor.nil?
        return "basis_unavailable" if basis_minor.nil? || rate_bps.nil?

        nil
      end
    end
  end
end
