# frozen_string_literal: true

module Marketplace
  module CommercialResaleTestHelpers
    include Commercial::FeeDefinitionTestHelpers

    def setup_commercial_resale_context
      @organization = organizations_organizations(:one)
      @event = events_events(:draft_concert)
      @quoted_at = Time.utc(2026, 8, 14, 10)
    end

    def commercial_context(**attributes)
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
          resale_acquisition_amount_minor: 1,
          accepted_paid_units: 0,
          accepted_gross_minor: 0,
          organizer_payer_selections: {}
        }.merge(attributes)
      )
    end

    def create_active_commercial_version(code:, schedule_type: "custom")
      schedule = create_schedule(code:, schedule_type:)
      version = create_version(schedule)
      yield version
      sync_definition_digest(version)
      version.update!(
        status: "active",
        effective_from: @quoted_at - 1.day,
        activated_by: core_users(:super_admin),
        activated_at: @quoted_at - 1.hour
      )
      version
    end

    def create_program_commercial_version(code:)
      schedule = create_schedule(code:, schedule_type: "program")
      program = Commercial::Program.create!(
        fee_schedule: schedule,
        program_type: "partnership",
        enrollment_mode: "manual",
        active: true
      )
      version = create_version(schedule)
      yield version
      sync_definition_digest(version)
      version.update!(
        status: "active",
        effective_from: @quoted_at - 1.day,
        activated_by: core_users(:super_admin),
        activated_at: @quoted_at - 1.hour
      )
      [ version, program ]
    end

    def create_active_commercial_assignment(version, attributes = {})
      Commercial::Assignment.create!(
        {
          organization: @organization,
          fee_schedule_version: version,
          assignment_type: "platform_grant",
          status: "active",
          reason: "resale fee resolution test",
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
          component_type:,
          calculation_type: "fixed",
          rate_bps: nil,
          basis_type: nil,
          charged_to: "buyer",
          funded_by: "buyer"
        }.merge(attributes)
      )
      currencies.each do |currency|
        create_amount(component, currency:, fixed_amount_minor:)
      end
      component
    end

    def resale_component(result)
      result.component_results.find { |component| component.component_type == "resale_platform_fee" }
    end

    def component_types(result)
      result.component_results.map(&:component_type)
    end
  end
end
