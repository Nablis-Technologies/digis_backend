# frozen_string_literal: true

require "test_helper"

module Commercial
  module Volume
    class RecordAcceptedOrderTest < ActiveSupport::TestCase
      include Commercial::VolumeTestHelpers

      setup do
        setup_volume_context
        @order = create_volume_order
        @component_result = build_component_result
      end

      test "records accepted units as immutable usage and increments the locked counter" do
        result = RecordAcceptedOrder.call(
          order: @order,
          component_results: [ @component_result ],
          accepted_paid_units: 3,
          accepted_at: @quoted_at
        )

        assert_predicate result, :success?, result.error&.message
        usage = Commercial::VolumeUsage.find_by(order: @order, fee_component: @component)
        counter = Commercial::VolumeCounter.find_by(fee_component: @component, event: @event)
        assert_equal 3, usage.value
        assert_equal 3, counter.value
        assert_equal @quoted_at, usage.accepted_at
      end

      test "replaying an accepted payment does not double count" do
        call = -> {
          RecordAcceptedOrder.call(
            order: @order,
            component_results: [ @component_result ],
            accepted_paid_units: 3,
            accepted_at: @quoted_at
          )
        }

        first = call.call
        second = call.call

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal 1, Commercial::VolumeUsage.where(order: @order).count
        assert_equal 3, Commercial::VolumeCounter.find_by!(fee_component: @component, event: @event).value
      end

      test "records accepted gross only in the matching settlement currency" do
        gross_component = create_tiered_component(
          { component_type: "buyer_service_fee", basis_type: "accepted_gross" },
          tiers: [ { metric_type: "accepted_gross", currency: "ETB" } ]
        )
        result = build_component_result(
          component: gross_component, metric_type: "accepted_gross", currency: "ETB", metric_value: 0,
          event_id: @event.id
        )

        recorded = RecordAcceptedOrder.call(
          order: @order,
          component_results: [ result ],
          accepted_gross_minor: 12_500,
          accepted_at: @quoted_at
        )

        assert_predicate recorded, :success?, recorded.error&.message
        usage = Commercial::VolumeUsage.find_by(order: @order, fee_component: gross_component)
        assert_equal 12_500, usage.value
        assert_equal "ETB", usage.currency
      end

      test "rejects a gross usage whose evidence currency differs from the order" do
        gross_component = create_tiered_component(
          { component_type: "buyer_service_fee", basis_type: "accepted_gross" },
          tiers: [ { metric_type: "accepted_gross", currency: "ETB" } ]
        )
        result = build_component_result(
          component: gross_component, metric_type: "accepted_gross", currency: "USD"
        )

        recorded = RecordAcceptedOrder.call(
          order: @order,
          component_results: [ result ],
          accepted_gross_minor: 12_500,
          accepted_at: @quoted_at
        )

        assert_predicate recorded, :failure?
        assert_equal "currency_mismatch", recorded.error.code
      end

      test "does not create usage for non-tiered commercial components" do
        result = build_component_result(calculation_type: "percentage")

        recorded = RecordAcceptedOrder.call(
          order: @order, component_results: [ result ], accepted_paid_units: 3
        )

        assert_predicate recorded, :success?, recorded.error&.message
        assert_empty Commercial::VolumeUsage.where(order: @order)
      end
    end
  end
end
