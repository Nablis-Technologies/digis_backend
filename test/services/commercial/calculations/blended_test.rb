# frozen_string_literal: true

require "test_helper"

module Commercial
  module Calculations
    class BlendedTest < ActiveSupport::TestCase
      test "calculates fixed then percentage and clamps the final result" do
        result = Blended.call(
          basis_minor: 10_001,
          fixed_amount_minor: 100,
          rate_bps: 750,
          maximum_minor: 800
        )

        assert_predicate result, :success?
        assert_equal 800, result.value.amount_minor
      end
    end
  end
end
