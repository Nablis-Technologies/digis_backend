# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ResaleFeeIsolationTest < ActionDispatch::IntegrationTest
    include CommercialResaleTestHelpers

    setup do
      setup_commercial_resale_context
    end

    test "keeps primary commission, resale fee, and buyer processing adjustments separate" do
      create_active_commercial_version(code: "resale_isolation", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 300,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end

      primary = Commercial::ResolveCharges.call(context: commercial_context)
      resale = Marketplace::ResolveResaleCharge.call(
        context: commercial_context,
        gross_amount_minor: 10_000
      )

      assert_predicate primary, :success?, primary.error&.message
      assert_predicate resale, :success?, resale.error&.message
      assert_nil primary.value.component_results.find { |component| component.component_type == "resale_platform_fee" }
      assert_nil resale.value.component_results.find { |component| component.component_type == "platform_commission" }
      assert_equal 300, resale_component(resale.value).amount_minor
      assert_equal 150, resale.value.buyer_fee_total
      assert_equal 300, resale.value.organizer_fee_total
      assert_equal "resale", resale_component(resale.value).scope[:sale_context]
      assert_includes resale_component(resale.value).explanation[:matched_scope], "sale_context"
    end
  end
end
