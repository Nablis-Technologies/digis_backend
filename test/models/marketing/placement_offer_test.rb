# frozen_string_literal: true

require "test_helper"

module Marketing
  class PlacementOfferTest < ActiveSupport::TestCase
    test "accepts a versioned ETB public discovery rate within the supported duration bounds" do
      offer = build_offer

      assert_predicate offer, :valid?, offer.errors.full_messages.join(", ")
    end

    test "rejects non-ETB rates and duration bounds outside the product contract" do
      offer = build_offer(currency: "USD", minimum_duration_seconds: 60, maximum_duration_seconds: 15.days.to_i)

      assert_not offer.valid?
      assert_includes offer.errors.attribute_names, :currency
      assert_includes offer.errors.attribute_names, :minimum_duration_seconds
      assert_includes offer.errors.attribute_names, :maximum_duration_seconds
    end

    test "requires a positive daily rate and a non-empty active interval" do
      offer = build_offer(daily_rate_minor: 0, starts_at: 2.days.from_now, ends_at: 1.day.from_now)

      assert_not offer.valid?
      assert_includes offer.errors.attribute_names, :daily_rate_minor
      assert_includes offer.errors.attribute_names, :ends_at
    end

    private

    def build_offer(**overrides)
      PlacementOffer.new({
        code: "public_discovery", version: 1, daily_rate_minor: 100_000, currency: "ETB",
        minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", active: true,
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      }.merge(overrides))
    end
  end
end
