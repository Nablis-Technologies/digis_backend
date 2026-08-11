# frozen_string_literal: true

require "test_helper"

module Commercial
  module Calculations
    class TieredTest < ActiveSupport::TestCase
      Tier = Data.define(
        :position, :metric_type, :window_type, :currency, :starts_at_value,
        :rate_bps, :fixed_amount_minor, :minimum_minor, :maximum_minor
      )

      test "selects the highest prospective tier at or below the committed counter" do
        result = Tiered.call(
          basis_minor: 10_001,
          metric_type: "accepted_paid_units",
          metric_value: 12,
          currency: "ETB",
          tiers: [
            tier(position: 1, starts_at_value: 0, rate_bps: 500),
            tier(position: 2, starts_at_value: 10, rate_bps: 1_000)
          ]
        )

        assert_predicate result, :success?
        assert_equal 1_000, result.value.amount_minor
        assert_equal 2, result.value.tier_position
        assert_equal 12, result.value.tier_metric_value
      end

      test "fails closed when no tier covers the committed counter" do
        result = Tiered.call(
          basis_minor: 10_001,
          metric_type: "accepted_paid_units",
          metric_value: 1,
          currency: "ETB",
          tiers: [ tier(position: 1, starts_at_value: 10, rate_bps: 500) ]
        )

        assert_predicate result, :failure?
        assert_equal "commercial_terms_unavailable", result.error.code
      end

      test "does not require a basis when the selected tier is fixed only" do
        result = Tiered.call(
          metric_type: "accepted_paid_units",
          metric_value: 12,
          currency: "ETB",
          tiers: [
            tier(position: 1, starts_at_value: 0, rate_bps: 500),
            tier(position: 2, starts_at_value: 10, rate_bps: nil, fixed_amount_minor: 125)
          ]
        )

        assert_predicate result, :success?
        assert_equal 125, result.value.amount_minor
        assert_nil result.value.basis_minor
      end

      private

      def tier(**attributes)
        Tier.new(
          **{
            position: 1,
            metric_type: "accepted_paid_units",
            window_type: "event",
            currency: nil,
            starts_at_value: 0,
            rate_bps: 500,
            fixed_amount_minor: nil,
            minimum_minor: nil,
            maximum_minor: nil
          }.merge(attributes)
        )
      end
    end
  end
end
