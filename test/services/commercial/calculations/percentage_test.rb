# frozen_string_literal: true

require "test_helper"

module Commercial
  module Calculations
    class PercentageTest < ActiveSupport::TestCase
      test "uses half-up rounding in integer minor units" do
        result = Percentage.call(basis_minor: 1, rate_bps: 5_000)

        assert_predicate result, :success?
        assert_equal 1, result.value.amount_minor
      end

      test "applies percentage minimum and maximum bounds" do
        result = Percentage.call(
          basis_minor: 10_000,
          rate_bps: 500,
          minimum_minor: 1_000,
          maximum_minor: 1_200
        )

        assert_predicate result, :success?
        assert_equal 1_000, result.value.amount_minor
      end
    end
  end
end
