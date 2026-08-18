# frozen_string_literal: true

require "test_helper"

module Marketplace
  class CalculatePriceCapTest < ActiveSupport::TestCase
    test "returns the configured fixed cap" do
      result = CalculatePriceCap.call(
        cap_type: "fixed",
        acquisition_product_value_minor: 10_000,
        fixed_cap_minor: 7_500
      )

      assert_predicate result, :success?
      assert_equal "fixed", result.value.cap_type
      assert_equal 7_500, result.value.calculated_cap_minor
      assert_equal 7_500, result.value.fixed_cap_minor
      assert_nil result.value.percentage_cap_bps
    end

    test "rounds a percentage cap half up from the seller acquisition value" do
      result = CalculatePriceCap.call(
        cap_type: "percentage",
        acquisition_product_value_minor: 10_001,
        percentage_cap_bps: 5_000
      )

      assert_predicate result, :success?
      assert_equal 5_001, result.value.calculated_cap_minor
      assert_nil result.value.fixed_cap_minor
      assert_equal 5_000, result.value.percentage_cap_bps
    end

    test "rejects a percentage cap for a free acquisition" do
      result = CalculatePriceCap.call(
        cap_type: "percentage",
        acquisition_product_value_minor: 0,
        percentage_cap_bps: 5_000
      )

      assert_predicate result, :failure?
      assert_equal "resale_acquisition_value_required", result.error.code
      assert_equal I18n.t("marketplace.resale.errors.resale_acquisition_value_required"), result.error.message
    end

    test "rejects competing cap inputs" do
      result = CalculatePriceCap.call(
        cap_type: "fixed",
        acquisition_product_value_minor: 10_000,
        fixed_cap_minor: 7_500,
        percentage_cap_bps: 5_000
      )

      assert_predicate result, :failure?
      assert_equal "resale_cap_shape_invalid", result.error.code
    end

    test "rejects unknown cap types" do
      result = CalculatePriceCap.call(
        cap_type: "tiered",
        acquisition_product_value_minor: 10_000,
        fixed_cap_minor: 7_500
      )

      assert_predicate result, :failure?
      assert_equal "resale_cap_type_invalid", result.error.code
    end
  end
end
