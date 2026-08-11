# frozen_string_literal: true

require_relative "fee_definition_test_helpers"

module Commercial
  # Builds the smallest real Commercial/Orders graph needed by Task 8 tests.
  # Volume evidence is created from accepted-order facts, so no seed rows are
  # introduced for counters, usages, or event payer choices.
  module VolumeTestHelpers
    include Commercial::FeeDefinitionTestHelpers

    def setup_volume_context
      @event = events_events(:draft_concert)
      @organization = Organizations::Organization.find(@event.organization_id)
      @quoted_at = Time.utc(2026, 8, 11, 10)
      @schedule = create_schedule(code: "volume_#{SecureRandom.hex(5)}")
      @version = create_version(@schedule)
      @component = create_tiered_component
    end

    def create_tiered_component(attributes = {}, tiers: [ {} ])
      component = create_component(
        @version,
        {
          calculation_type: "tiered",
          rate_bps: nil,
          basis_type: "eligible_order_subtotal",
          label: "Volume commission"
        }.merge(attributes)
      )
      tiers.each_with_index do |tier_attributes, index|
        create_tier(
          component,
          {
            position: index + 1,
            metric_type: "accepted_paid_units",
            window_type: "event",
            starts_at_value: index.zero? ? 0 : index * 10,
            rate_bps: index.zero? ? 500 : 250
          }.merge(tier_attributes)
        )
      end
      component
    end

    def create_volume_order(status: "paid", settlement_total_minor: 10_000,
      settlement_currency: "ETB", event: @event)
      Orders::Order.create!(
        event:,
        buyer_user: core_users(:attendee),
        sales_channel: "online",
        status:,
        charge_currency: settlement_currency,
        subtotal_minor: settlement_total_minor,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: settlement_total_minor,
        settlement_currency:,
        settlement_total_minor:,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: @quoted_at + 10.minutes,
        expires_at: @quoted_at + 10.minutes,
        paid_at: status.in?(Orders::Order::PAID_STATUSES) ? @quoted_at : nil,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
    end

    def build_component_result(component: @component, metric_type: "accepted_paid_units", window_type: "event",
      event_id: @event.id, window_start_at: @quoted_at - 1.day,
      window_end_at: @quoted_at + 1.day, counter_value_before: 0,
      metric_value: counter_value_before, currency: "ETB", calculation_type: "tiered")
      Commercial::Resolution::ComponentResult.new(
        component_type: component.component_type,
        label: component.label,
        currency:,
        amount_minor: 500,
        signed_amount_minor: 500,
        schedule_id: @schedule.id,
        schedule_code: @schedule.code,
        schedule_type: @schedule.schedule_type,
        version_id: @version.id,
        version_number: @version.version,
        definition_digest: @version.definition_digest,
        assignment_id: nil,
        program_id: nil,
        component_id: component.id,
        calculation_type:,
        basis_type: "eligible_order_subtotal",
        basis_minor: 10_000,
        rate_bps: 500,
        fixed_amount_minor: nil,
        minimum_minor: nil,
        maximum_minor: nil,
        tier_position: 1,
        tier_metric_type: metric_type,
        tier_metric_value: metric_value,
        tier_window_type: window_type,
        tier_starts_at_value: 0,
        payer: component.charged_to,
        default_payer: component.charged_to,
        funder: component.funded_by,
        refund_policy: component.refund_policy,
        offset_component_type: nil,
        scope: {},
        explanation: { source: :platform_default, specificity: [] },
        volume_organization_id: @organization.id,
        volume_event_id: event_id,
        volume_counter_id: nil,
        volume_counter_value_before: counter_value_before,
        volume_window_start_at: window_start_at,
        volume_window_end_at: window_end_at,
        volume_currency: metric_type == "accepted_gross" ? currency : nil
      )
    end
  end
end
