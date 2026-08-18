# frozen_string_literal: true

require "test_helper"

module Commercial
  module Shadow
    class CompareTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(code: "task12_shadow")
        @context = simulation_scenario
      end

      test "compares proposed definitions without creating checkout records" do
        order_count = Orders::Order.count

        result = Commercial::Shadow::Compare.call(
          proposed_version: @version,
          baseline_version: @version,
          contexts: [ @context ]
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal [ "match" ], result.value.fetch(:comparisons).map { |row| row.fetch(:status) }
        assert_equal order_count, Orders::Order.count
        assert_empty Core::OutboxEvent.where(event_type: "commercial.operational_alert")
      end

      test "records a deduplicated fail-closed alert for a resolution gap" do
        invalid_context = @context.except(:item_face_value_minor, :eligible_order_subtotal_minor)

        first = Commercial::Shadow::Compare.call(
          proposed_version: @version,
          baseline_version: @version,
          contexts: [ invalid_context ]
        )
        second = Commercial::Shadow::Compare.call(
          proposed_version: @version,
          baseline_version: @version,
          contexts: [ invalid_context ]
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal [ "gap" ], first.value.fetch(:comparisons).map { |row| row.fetch(:status) }
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.operational_alert").count
        assert_equal "commercial_resolution_gap", Core::AuditLog.where(action: "commercial.operational_alert").sole.metadata.fetch("kind")
      end
    end
  end
end
