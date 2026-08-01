# frozen_string_literal: true

require "test_helper"

module Catalog
  class PromotionTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
    end

    test "disables STI on the type column" do
      assert_predicate Catalog::Promotion.inheritance_column, :blank?
    end

    test "requires exactly one calculation value for percentage promotions" do
      promotion = build_promotion(
        type: "percentage",
        percentage_basis_points: 1_000,
        fixed_amount_minor: 100
      )

      assert_not promotion.valid?
      assert_includes promotion.errors[:base], I18n.t("catalog.promotion.errors.calculation_exclusive")
    end

    test "requires fixed amount for fixed promotions" do
      promotion = build_promotion(type: "fixed", fixed_amount_minor: nil)

      assert_not promotion.valid?
      assert_includes promotion.errors[:fixed_amount_minor], I18n.t("catalog.promotion.errors.invalid_fixed_amount")
    end

    test "rejects percentages outside the allowed basis-point range" do
      promotion = build_promotion(type: "percentage", percentage_basis_points: 10_001)

      assert_not promotion.valid?
      assert_includes promotion.errors[:percentage_basis_points], I18n.t("catalog.promotion.errors.invalid_percentage_basis_points")
    end

    test "defaults per-user limit to one" do
      promotion = build_promotion(type: "fixed", fixed_amount_minor: 500)

      assert_equal 1, promotion.per_user_limit
    end

    test "requires promotion end after start" do
      promotion = build_promotion(
        type: "fixed",
        fixed_amount_minor: 500,
        starts_at: 2.days.from_now,
        ends_at: 1.day.from_now
      )

      assert_not promotion.valid?
      assert_includes promotion.errors[:ends_at], I18n.t("catalog.promotion.errors.invalid_window")
    end

    test "exposes only safe ransack attributes" do
      assert_includes Catalog::Promotion.ransackable_attributes, "name"
      assert_not_includes Catalog::Promotion.ransackable_attributes, "code_ciphertext"
    end

    private

    def build_promotion(attributes = {})
      Catalog::Promotion.new(
        {
          event: @event,
          name: "Opening discount",
          type: "percentage",
          percentage_basis_points: 1_000,
          currency: "ETB",
          status: "draft",
          per_user_limit: 1
        }.merge(attributes)
      )
    end
  end
end
