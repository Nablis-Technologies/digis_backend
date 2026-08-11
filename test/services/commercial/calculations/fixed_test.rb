# frozen_string_literal: true

require "test_helper"

module Commercial
  module Calculations
    class FixedTest < ActiveSupport::TestCase
      test "uses the currency-specific fixed amount and clamps it" do
        result = Fixed.call(fixed_amount_minor: 1_500, minimum_minor: 1_000, maximum_minor: 1_200)

        assert_predicate result, :success?
        assert_equal 1_200, result.value.amount_minor
      end

      test "fails when fixed currency coverage is missing" do
        result = Fixed.call

        assert_predicate result, :failure?
        assert_equal "commercial_terms_unavailable", result.error.code
      end
    end
  end
end
