# frozen_string_literal: true

require "json"
require "test_helper"

module Commercial
  class ResolveChargesTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    setup do
      @organization = organizations_organizations(:one)
      @event = events_events(:draft_concert)
      @quoted_at = Time.utc(2026, 8, 11, 10)
    end

    test "resolves each component through event, organization, program, and default layers" do
      default_version = create_active_version(code: "default_precedence", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000, label: "Default commission")
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500, label: "Default processing"
        )
      end
      program_version = create_program_version(code: "program_precedence") do |version|
        create_component(version, rate_bps: 800, label: "Program commission")
      end
      create_active_assignment(
        program_version,
        assignment_type: "program",
        program: program_for(program_version)
      )
      organization_version = create_active_version(code: "organization_precedence") do |version|
        create_component(
          version, calculation_type: "explicit_zero", rate_bps: nil, basis_type: nil,
          charged_to: "organizer", funded_by: "organizer", label: "Organization waiver"
        )
      end
      create_active_assignment(organization_version, assignment_type: "platform_grant")
      event_version = create_active_version(code: "event_precedence") do |version|
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 25)
      end
      create_active_assignment(event_version, assignment_type: "platform_grant", event: @event)

      result = Commercial::ResolveCharges.call(context: context)

      assert_predicate result, :success?, result.error&.message
      charge_result = result.value
      assert_equal 0, component(charge_result, "platform_commission").amount_minor
      assert_equal 25, component(charge_result, "buyer_service_fee").amount_minor
      assert_equal 500, component(charge_result, "processing_cost_recovery").amount_minor
      assert_equal "organization_assignment", component(charge_result, "platform_commission").explanation[:source]
      assert_equal "event_assignment", component(charge_result, "buyer_service_fee").explanation[:source]
      assert_equal "platform_default", component(charge_result, "processing_cost_recovery").explanation[:source]
      assert_equal default_version.fee_schedule_id, component(charge_result, "processing_cost_recovery").schedule_id
    end

    test "returns unavailable when a required component is absent or lacks currency coverage" do
      create_active_version(code: "missing_component", schedule_type: "platform_default") do |version|
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
      end

      missing_component = Commercial::ResolveCharges.call(context: context)
      assert_predicate missing_component, :failure?
      assert_equal "commercial_terms_unavailable", missing_component.error.code

      missing_currency_version = create_active_version(code: "missing_currency") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100, currencies: [ "ETB" ])
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
      end
      create_active_assignment(missing_currency_version, event: @event)

      missing_currency = Commercial::ResolveCharges.call(context: context(currency: "USD"))
      assert_predicate missing_currency, :failure?
      assert_equal "commercial_terms_unavailable", missing_currency.error.code
    end

    test "keeps primary and resale fee components isolated" do
      create_active_version(code: "primary_and_resale", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
        create_fixed_component(
          version, component_type: "resale_platform_fee", fixed_amount_minor: 300,
          sale_context: "resale", sales_channel: "resale", charged_to: "organizer", funded_by: "organizer"
        )
      end

      primary = Commercial::ResolveCharges.call(context: context)
      assert_predicate primary, :success?, primary.error&.message
      refute component_types(primary.value).include?("resale_platform_fee")

      resale = Commercial::ResolveCharges.call(
        context: context(
          sale_context: "resale", sales_channel: "resale", resale_acquisition_amount_minor: 10_000
        )
      )
      assert_predicate resale, :success?, resale.error&.message
      assert_equal 300, component(resale.value, "resale_platform_fee").amount_minor
      refute component_types(resale.value).include?("platform_commission")
    end

    test "honors organizer payer selection only when the component permits it" do
      create_active_version(code: "payer_selection", schedule_type: "platform_default") do |version|
        create_component(version, charged_to: "organizer", funded_by: "organizer", organizer_payer_choice: true, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
      end

      selected = Commercial::ResolveCharges.call(
        context: context(organizer_payer_selections: { platform_commission: "buyer" })
      )
      assert_predicate selected, :success?, selected.error&.message
      assert_equal "buyer", component(selected.value, "platform_commission").payer
      assert_equal 1_600, selected.value.buyer_fee_total

      forbidden_version = create_active_version(code: "payer_forbidden") do |version|
        create_component(version, charged_to: "organizer", funded_by: "organizer", rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
      end
      create_active_assignment(forbidden_version, event: @event)

      forbidden = Commercial::ResolveCharges.call(
        context: context(organizer_payer_selections: { platform_commission: "buyer" })
      )
      assert_predicate forbidden, :failure?
      assert_equal "payer_selection_forbidden", forbidden.error.code
    end

    test "includes platform subsidies as separate signed adjustments" do
      create_active_version(code: "subsidy_result", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
        create_component(
          version, component_type: "platform_subsidy", charged_to: "buyer", funded_by: "platform",
          offset_component_type: "buyer_service_fee", rate_bps: 250
        )
      end

      result = Commercial::ResolveCharges.call(context: context)

      assert_predicate result, :success?, result.error&.message
      subsidy = component(result.value, "platform_subsidy")
      assert_equal 250, subsidy.amount_minor
      assert_equal(-250, subsidy.signed_amount_minor)
      assert_equal 250, result.value.subsidy_total
      assert_includes component_types(result.value), "platform_subsidy"
    end

    test "snapshots the committed counter and selected tier evidence" do
      create_active_version(code: "tier_evidence", schedule_type: "platform_default") do |version|
        tiered = create_component(
          version, calculation_type: "tiered", rate_bps: nil,
          basis_type: "eligible_order_subtotal"
        )
        create_tier(tiered, starts_at_value: 0, rate_bps: 500)
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
      end

      result = Commercial::ResolveCharges.call(context: context(accepted_paid_units: 12))

      assert_predicate result, :success?, result.error&.message
      commission = component(result.value, "platform_commission")
      assert_equal 1, commission.tier_position
      assert_equal "accepted_paid_units", commission.tier_metric_type
      assert_equal 12, commission.tier_metric_value
      assert_equal "event", commission.tier_window_type
      assert_equal 0, commission.tier_starts_at_value
    end

    test "returns deeply frozen scalar evidence with deterministic serialization" do
      create_active_version(code: "immutable_result", schedule_type: "platform_default") do |version|
        create_component(version, rate_bps: 1_000, label: "Public commission")
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_component(
          version, component_type: "processing_cost_recovery", charged_to: "buyer", funded_by: "buyer",
          rate_bps: 500
        )
      end

      result = Commercial::ResolveCharges.call(context: context)
      assert_predicate result, :success?, result.error&.message
      charge_result = result.value
      serialized = JSON.generate(charge_result.to_h)

      assert_predicate charge_result, :frozen?
      assert_predicate charge_result.definition_signature, :frozen?
      assert_predicate charge_result.overall_signature, :frozen?
      assert_deeply_frozen(charge_result.to_h)
      assert_equal serialized, JSON.generate(charge_result.to_h)
      assert_equal charge_result.overall_signature, charge_result.signature
      charge_result.component_results.each do |component_result|
        refute_instance_of Commercial::FeeComponent, component_result
        refute_includes component_result.to_h.keys, :reason
      end
      refute_includes serialized, "internal negotiation"
    end

    private

    def context(**attributes)
      Commercial::Resolution::Context.new(
        {
          organization_id: @organization.id,
          event_id: @event.id,
          product_type: "ticket",
          sale_context: "primary",
          provider: "chapa",
          payment_method: "card",
          sales_channel: "online",
          currency: "ETB",
          settlement_currency: "ETB",
          quoted_at: @quoted_at,
          item_face_value_minor: 10_001,
          item_net_value_after_organizer_promotion_minor: 10_001,
          eligible_order_subtotal_minor: 10_001,
          resale_acquisition_amount_minor: 10_001,
          accepted_paid_units: 0,
          accepted_gross_minor: 0,
          organizer_payer_selections: {}
        }.merge(attributes)
      )
    end

    def create_active_version(code:, schedule_type: "custom")
      schedule = create_schedule(code:, schedule_type:)
      version = create_version(schedule, status: "draft")
      yield version
      sync_definition_digest(version)
      version.update!(
        status: "active", effective_from: @quoted_at - 1.day,
        activated_by: core_users(:super_admin), activated_at: @quoted_at - 1.hour
      )
      version
    end

    def create_program_version(code:)
      schedule = create_schedule(code:, schedule_type: "program")
      program = Commercial::Program.create!(
        fee_schedule: schedule, program_type: "partnership", enrollment_mode: "manual", active: true
      )
      version = create_version(schedule)
      yield version
      sync_definition_digest(version)
      version.update!(
        status: "active", effective_from: @quoted_at - 1.day,
        activated_by: core_users(:super_admin), activated_at: @quoted_at - 1.hour
      )
      @programs_by_schedule_id ||= {}
      @programs_by_schedule_id[schedule.id] = program
      version
    end

    def program_for(version)
      @programs_by_schedule_id.fetch(version.fee_schedule_id)
    end

    def create_active_assignment(version, attributes = {})
      Commercial::Assignment.create!(
        {
          organization: @organization,
          fee_schedule_version: version,
          assignment_type: "platform_grant",
          status: "active",
          reason: "internal negotiation evidence must never enter a quote",
          effective_from: @quoted_at - 1.day,
          risk_level: "low",
          baseline_resolution_digest: "a" * 64,
          activated_by: core_users(:super_admin),
          activated_at: @quoted_at - 1.hour,
          created_by: core_users(:super_admin)
        }.merge(attributes)
      )
    end

    def create_fixed_component(version, component_type:, fixed_amount_minor:, currencies: [ "ETB" ], **attributes)
      component = create_component(
        version,
        {
          component_type:, calculation_type: "fixed", rate_bps: nil, basis_type: nil,
          charged_to: "buyer", funded_by: "buyer"
        }.merge(attributes)
      )
      currencies.each do |currency|
        create_amount(component, currency:, fixed_amount_minor:)
      end
      component
    end

    def component(result, component_type)
      result.component_results.find { |item| item.component_type == component_type }
    end

    def component_types(result)
      result.component_results.map(&:component_type)
    end

    def assert_deeply_frozen(value)
      assert_predicate value, :frozen?
      children = value.is_a?(Hash) ? value.keys + value.values : value
      children = [ value ] unless value.is_a?(Array) || value.is_a?(Hash)
      children.each { |child| assert_deeply_frozen(child) if child.is_a?(Array) || child.is_a?(Hash) }
      children.each { |child| assert_predicate child, :frozen? if child.is_a?(String) || child.is_a?(Symbol) }
    end
  end
end
