# frozen_string_literal: true

require "test_helper"

module Orders
  class CommercialAdjustmentWriterTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    setup do
      @event = events_events(:draft_concert)
      @buyer = core_users(:attendee)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Adjustment product",
        type: "parking",
        status: "active",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      @order = Orders::Order.create!(order_attributes)
      @order_item = @order.order_items.create!(
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: @product.type,
        quantity: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 1_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 1_000,
        exchange_rate: 1,
        total_minor: 1_000,
        fulfillment_status: "pending"
      )
      @component = build_component_result
    end

    test "writes a signed immutable adjustment from the Commercial value object" do
      result = Orders::CommercialAdjustmentWriter.call(
        order: @order,
        order_item: @order_item,
        charge_result: Commercial::Resolution::ChargeResult.new(
          currency: "ETB",
          quoted_at: Time.current,
          component_results: [ @component ],
          buyer_fee_total: 125,
          organizer_fee_total: 0,
          subsidy_total: 0
        )
      )

      assert_predicate result, :success?, result.error&.message
      adjustment = result.value.sole
      assert_equal "service_fee", adjustment.type
      assert_equal 125, adjustment.amount_minor
      assert_equal @component.component_id, adjustment.source_id
      assert_equal "Commercial::FeeComponent", adjustment.source_type
      assert_equal @component.version_id, adjustment.resolution_evidence.fetch("scope").fetch("version_id")
      assert_equal "half_up", adjustment.resolution_evidence.fetch("rounding").fetch("mode")
    end

    test "commercial signatures change when provider context or results change" do
      charge_result = Commercial::Resolution::ChargeResult.new(
        currency: "ETB",
        quoted_at: Time.current,
        component_results: [ @component ],
        buyer_fee_total: 125,
        organizer_fee_total: 0,
        subsidy_total: 0
      )

      first = Orders::CommercialSignature.call(
        commercial_results: [ charge_result ], provider: "chapa",
        payment_method: "telebirr", charge_currency: "ETB"
      )
      same = Orders::CommercialSignature.call(
        commercial_results: [ charge_result ], provider: "chapa",
        payment_method: "telebirr", charge_currency: "ETB"
      )
      changed = Orders::CommercialSignature.call(
        commercial_results: [ charge_result ], provider: "stripe",
        payment_method: "card", charge_currency: "ETB"
      )

      assert_equal first, same
      refute_equal first, changed
      assert_match(/\A[0-9a-f]{64}\z/, first)
    end

    private

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        subtotal_minor: 1_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 1_000,
        settlement_currency: "ETB",
        settlement_total_minor: 1_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def build_component_result
      schedule = create_schedule(code: "writer_#{SecureRandom.hex(5)}")
      version = create_version(schedule, effective_from: 1.day.ago)
      component = create_component(
        version,
        component_type: "buyer_service_fee",
        charged_to: "buyer",
        funded_by: "buyer",
        basis_type: "eligible_order_subtotal",
        rate_bps: 1_250,
        label: "Buyer service fee"
      )

      Commercial::Resolution::ComponentResult.new(
        component_type: component.component_type,
        label: component.label,
        currency: "ETB",
        amount_minor: 125,
        signed_amount_minor: 125,
        schedule_id: schedule.id,
        schedule_code: schedule.code,
        schedule_type: schedule.schedule_type,
        version_id: version.id,
        version_number: version.version,
        definition_digest: version.definition_digest,
        assignment_id: nil,
        program_id: nil,
        component_id: component.id,
        calculation_type: component.calculation_type,
        basis_type: component.basis_type,
        basis_minor: 1_000,
        rate_bps: 1_250,
        fixed_amount_minor: nil,
        minimum_minor: nil,
        maximum_minor: nil,
        tier_position: nil,
        tier_metric_type: nil,
        tier_metric_value: nil,
        tier_window_type: nil,
        tier_starts_at_value: nil,
        payer: "buyer",
        default_payer: "buyer",
        funder: "buyer",
        refund_policy: "nonrefundable",
        volume_organization_id: nil,
        volume_event_id: nil,
        volume_counter_id: nil,
        volume_counter_value_before: nil,
        volume_window_start_at: nil,
        volume_window_end_at: nil,
        volume_currency: nil,
        offset_component_type: nil,
        scope: { version_id: version.id },
        explanation: { source: "platform_default" }
      )
    end
  end
end
