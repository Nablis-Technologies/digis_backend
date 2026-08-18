# frozen_string_literal: true

require "test_helper"

module Commercial
  module Volume
    class ReconcileTest < ActiveSupport::TestCase
      include Commercial::VolumeTestHelpers

      setup do
        setup_volume_context
        @order = create_volume_order
        @counter = Commercial::VolumeCounter.create!(
          fee_component: @component,
          organization: @organization,
          event: @event,
          metric_type: "accepted_paid_units",
          window_type: "event",
          window_start_at: @quoted_at - 1.day,
          window_end_at: @quoted_at + 1.day,
          value: 99,
          lock_version: 0
        )
        Commercial::VolumeUsage.create!(
          fee_component: @component,
          organization: @organization,
          event: @event,
          order: @order,
          metric_type: "accepted_paid_units",
          window_type: "event",
          window_start_at: @counter.window_start_at,
          window_end_at: @counter.window_end_at,
          value: 3,
          accepted_at: @quoted_at
        )
      end

      test "repairs a counter from immutable usage truth" do
        result = Reconcile.call(counter: @counter)

        assert_predicate result, :success?, result.error&.message
        assert_equal 3, result.value.value
      end

      test "is idempotent when the counter already matches usage" do
        @counter.update!(value: 3)
        first = Reconcile.call(counter: @counter)
        second = Reconcile.call(counter: @counter)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal 3, second.value.value
      end
    end
  end
end
