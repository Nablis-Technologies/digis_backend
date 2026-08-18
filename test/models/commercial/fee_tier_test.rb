# frozen_string_literal: true

require "test_helper"

module Commercial
  class FeeTierTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    setup do
      @component = create_component(
        create_version(create_schedule),
        calculation_type: "tiered",
        basis_type: "accepted_paid_units",
        rate_bps: nil
      )
    end

    test "allows accepted-unit tiers without currency and requires currency for gross tiers" do
      units = @component.fee_tiers.build(
        position: 1, metric_type: "accepted_paid_units", window_type: "event",
        starts_at_value: 0, rate_bps: 500
      )
      gross = @component.fee_tiers.build(
        position: 1, metric_type: "accepted_gross", window_type: "event",
        starts_at_value: 0, rate_bps: 500
      )

      assert_predicate units, :valid?
      assert_not gross.valid?
      assert_includes gross.errors[:currency], "is required for accepted gross tiers"
    end

    test "validates tier metrics, windows, thresholds, rates, and bounds" do
      invalid_metric = @component.fee_tiers.build(
        position: 1, metric_type: "orders", window_type: "event", starts_at_value: 0
      )
      invalid_window = @component.fee_tiers.build(
        position: 1, metric_type: "accepted_paid_units", window_type: "week",
        starts_at_value: 0
      )
      invalid_threshold = @component.fee_tiers.build(
        position: 1, metric_type: "accepted_paid_units", window_type: "event",
        starts_at_value: -1
      )

      [ invalid_metric, invalid_window, invalid_threshold ].each do |tier|
        assert_not tier.valid?
      end

      assert_includes invalid_threshold.errors[:starts_at_value], "must be greater than or equal to 0"
    end

    test "enforces one position per component and immutable nested definitions" do
      @component.fee_tiers.create!(position: 1, metric_type: "accepted_paid_units", window_type: "event", starts_at_value: 0)
      duplicate = @component.fee_tiers.build(
        position: 1, metric_type: "accepted_paid_units", window_type: "event", starts_at_value: 100
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:position], "has already been taken"

      @component.fee_schedule_version.update!(
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current,
        effective_from: 1.hour.from_now
      )
      duplicate.position = 2

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:base], I18n.t("commercial.definitions.errors.immutable")
    end

    test "database blocks bulk tier edits after approval" do
      tier = create_tier(@component)
      @component.fee_schedule_version.update!(
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current,
        effective_from: 1.hour.from_now
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Commercial::FeeTier.where(id: tier.id).update_all(rate_bps: 999)
      end
    end
  end
end
