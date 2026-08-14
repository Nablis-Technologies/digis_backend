# frozen_string_literal: true

require "test_helper"

module Marketplace
  class CommercialResaleFeeTest < ActiveSupport::TestCase
    include CommercialResaleTestHelpers

    setup do
      setup_commercial_resale_context
    end

    test "resolves the event resale fee without inheriting primary commission" do
      create_active_commercial_version(code: "resale_default", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(
          version,
          component_type: "processing_cost_recovery",
          fixed_amount_minor: 50
        )
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
      event_version = create_active_commercial_version(code: "resale_event") do |version|
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 225,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end
      create_active_commercial_assignment(event_version, event: @event)

      result = Marketplace::ResolveResaleCharge.call(
        context: commercial_context,
        gross_amount_minor: 10_000
      )

      assert_predicate result, :success?, result.error&.message
      charge_result = result.value
      assert_equal %w[buyer_service_fee processing_cost_recovery resale_platform_fee], component_types(charge_result)
      assert_nil charge_result.component_results.find { |component| component.component_type == "platform_commission" }
      assert_equal 225, resale_component(charge_result).amount_minor
      assert_equal "event_assignment", resale_component(charge_result).explanation[:source]
      assert_equal event_version.id, resale_component(charge_result).version_id
      assert_equal event_version.definition_digest, resale_component(charge_result).definition_digest
      assert_predicate charge_result, :frozen?
      assert_predicate resale_component(charge_result), :frozen?
    end

    test "uses event, organization, program, then default resale precedence" do
      default_version = create_active_commercial_version(code: "resale_precedence_default", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 100,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end
      program_version, program = create_program_commercial_version(code: "resale_precedence_program") do |version|
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 200,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end
      organization_version = create_active_commercial_version(code: "resale_precedence_organization") do |version|
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
      event_version = create_active_commercial_version(code: "resale_precedence_event") do |version|
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 400,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end
      program_assignment = create_active_commercial_assignment(
        program_version,
        assignment_type: "program",
        program:
      )
      organization_assignment = create_active_commercial_assignment(organization_version)
      event_assignment = create_active_commercial_assignment(event_version, event: @event)

      result = Marketplace::ResolveResaleCharge.call(context: commercial_context, gross_amount_minor: 10_000)
      assert_equal 400, resale_component(result.value).amount_minor

      event_assignment.destroy!
      result = Marketplace::ResolveResaleCharge.call(context: commercial_context, gross_amount_minor: 10_000)
      assert_equal 300, resale_component(result.value).amount_minor

      organization_assignment.destroy!
      result = Marketplace::ResolveResaleCharge.call(context: commercial_context, gross_amount_minor: 10_000)
      assert_equal 200, resale_component(result.value).amount_minor

      program_assignment.destroy!
      result = Marketplace::ResolveResaleCharge.call(context: commercial_context, gross_amount_minor: 10_000)
      assert_equal 100, resale_component(result.value).amount_minor
      assert_equal default_version.id, resale_component(result.value).version_id
    end

    test "selects one most-specific bounded resale component without stacking" do
      create_active_commercial_version(code: "resale_specificity", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 300,
          sale_context: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 450,
          product_type: "ticket",
          sale_context: "resale",
          provider: "chapa",
          payment_method: "card",
          sales_channel: "resale",
          currency: "ETB",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end

      result = Marketplace::ResolveResaleCharge.call(
        context: commercial_context,
        gross_amount_minor: 10_000
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 450, resale_component(result.value).amount_minor
      assert_equal 1, result.value.component_results.count { |component|
        component.component_type == "resale_platform_fee"
      }
      assert_equal 150, result.value.buyer_fee_total
      assert_equal 450, result.value.organizer_fee_total
    end

    test "uses the trusted gross as the resale calculation basis" do
      create_active_commercial_version(code: "resale_basis", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
        create_component(
          version,
          component_type: "resale_platform_fee",
          calculation_type: "percentage",
          charged_to: "organizer",
          funded_by: "organizer",
          basis_type: "resale_acquisition_amount",
          rate_bps: 1_000,
          sale_context: "resale",
          sales_channel: "resale"
        )
      end

      result = Marketplace::ResolveResaleCharge.call(
        context: commercial_context(resale_acquisition_amount_minor: 1),
        gross_amount_minor: 10_000
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 10_000, resale_component(result.value).basis_minor
      assert_equal 1_000, resale_component(result.value).amount_minor
    end

    test "fails closed when the resale fee exceeds gross" do
      create_active_commercial_version(code: "resale_over_gross", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
        create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 10_001,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end

      result = Marketplace::ResolveResaleCharge.call(
        context: commercial_context,
        gross_amount_minor: 10_000
      )

      assert_predicate result, :failure?
      assert_equal "resale_fee_exceeds_gross", result.error.code
    end

    test "does not invent a zero resale fee when Commercial terms are unavailable" do
      create_active_commercial_version(code: "resale_missing", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
      end

      result = Marketplace::ResolveResaleCharge.call(
        context: commercial_context,
        gross_amount_minor: 10_000
      )

      assert_predicate result, :failure?
      assert_equal "commercial_terms_unavailable", result.error.code
    end
  end
end
