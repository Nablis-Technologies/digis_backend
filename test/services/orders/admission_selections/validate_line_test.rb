# frozen_string_literal: true

require "test_helper"

module Orders
  module AdmissionSelections
    class ValidateLineTest < ActiveSupport::TestCase
      test "a ticket without a ticket type has one shared unprocessable product error" do
        result = ValidateLine.call(
          item: { answers: [], consents: [] },
          product: Catalog::EventProduct.new(type: "ticket")
        )

        assert_predicate result, :failure?
        assert_equal "product_unavailable", result.error.code
        assert_equal :unprocessable_entity, result.error.status
      end

      test "rejects ticket-only fields on an add-on" do
        result = ValidateLine.call(
          item: { registration_id: "registration-1" },
          product: Catalog::EventProduct.new(type: "merchandise")
        )

        assert_predicate result, :failure?
        assert_equal "admission_selection_invalid", result.error.code
      end

      test "reports missing parking access as unavailable product rather than invalid date" do
        result = ValidateLine.call(
          item: {},
          product: Catalog::EventProduct.new(type: "parking")
        )

        assert_predicate result, :failure?
        assert_equal "product_unavailable", result.error.code
        assert_equal :unprocessable_entity, result.error.status
      end
    end
  end
end
