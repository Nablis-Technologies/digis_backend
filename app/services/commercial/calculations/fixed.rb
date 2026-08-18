# frozen_string_literal: true

module Commercial
  module Calculations
    # Returns the explicit fixed minor-unit amount for the requested currency,
    # then applies its declared minimum and maximum bounds.
    class Fixed < Base
      private

      def calculate_amount
        clamp(fixed_amount_minor)
      end

      def configuration_error_code
        "commercial_terms_unavailable" if fixed_amount_minor.nil?
      end
    end
  end
end
