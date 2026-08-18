# frozen_string_literal: true

module Commercial
  module FeeDefinitionTestHelpers
    DEFAULT_DIGEST = "a" * 64

    def build_schedule(attributes = {})
      Commercial::FeeSchedule.new(
        {
          name: "Test fee schedule",
          code: "test_schedule",
          schedule_type: "custom",
          created_by: core_users(:super_admin)
        }.merge(attributes)
      )
    end

    def create_schedule(attributes = {})
      build_schedule(attributes).tap(&:save!)
    end

    def build_version(schedule, attributes = {})
      schedule.fee_schedule_versions.build(
        {
          version: 1,
          status: "draft",
          definition_digest: DEFAULT_DIGEST,
          acceptance_policy: "none"
        }.merge(attributes)
      )
    end

    def create_version(schedule, attributes = {})
      build_version(schedule, attributes).tap(&:save!)
    end

    def build_component(version, attributes = {})
      version.fee_components.build(
        {
          component_type: "platform_commission",
          calculation_type: "percentage",
          charged_to: "organizer",
          organizer_payer_choice: false,
          funded_by: "organizer",
          basis_type: "eligible_order_subtotal",
          rate_bps: 750,
          refund_policy: "nonrefundable",
          label: "Platform commission"
        }.merge(attributes)
      )
    end

    def create_component(version, attributes = {})
      build_component(version, attributes).tap(&:save!)
    end

    def create_amount(component, attributes = {})
      component.fee_amounts.create!(
        {
          currency: "ETB",
          fixed_amount_minor: 100
        }.merge(attributes)
      )
    end

    def create_tier(component, attributes = {})
      component.fee_tiers.create!(
        {
          position: 1,
          metric_type: "accepted_paid_units",
          window_type: "event",
          starts_at_value: 0,
          rate_bps: 500
        }.merge(attributes)
      )
    end

    def create_product(event: events_events(:ready_listing), attributes: {})
      Catalog::EventProduct.create!(
        {
          event: event,
          name: "Parking product",
          type: "parking",
          status: "draft",
          inventory_mode: "unlimited",
          schedule_change_refund_policy: "full_or_partial",
          min_per_order: 1
        }.merge(attributes)
      )
    end

    def sync_definition_digest(version)
      result = Commercial::Definitions::Canonicalize.call(version: version)
      version.update!(definition_digest: result.value.digest)
      result.value.digest
    end
  end
end
