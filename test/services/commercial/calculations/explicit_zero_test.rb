# frozen_string_literal: true

require "test_helper"

module Commercial
  module Calculations
    class ExplicitZeroTest < ActiveSupport::TestCase
      test "returns zero without requiring a basis" do
        result = ExplicitZero.call

        assert_predicate result, :success?
        assert_equal 0, result.value.amount_minor
      end
    end
  end
end
