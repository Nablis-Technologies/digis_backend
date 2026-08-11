# frozen_string_literal: true

module Commercial
  module Calculations
    # Produces an explicit zero charge. This is distinct from a missing
    # component, which the resolver reports as unavailable and never as zero.
    class ExplicitZero < Base
      private

      def calculate_amount
        0
      end
    end
  end
end
