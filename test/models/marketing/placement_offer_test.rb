# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  class PlacementOfferTest < ActiveSupport::TestCase
    test "offers use an explicit versioned lifecycle" do
      columns = PlacementOffer.columns_hash.keys

      %w[status created_by_id activated_by_id retired_by_id activated_at retired_at
        idempotency_key_digest request_digest].each do |column|
        assert_includes columns, column
      end
      refute_includes columns, "active"
    end

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

    test "active_at uses the half-open offer window" do
      now = Time.current
      offer = build_offer(code: "window_#{SecureRandom.hex(4)}", starts_at: now - 1.hour, ends_at: now + 1.hour)
      offer.save!

      assert_includes PlacementOffer.active_at(now), offer
      refute_includes PlacementOffer.active_at(offer.ends_at), offer
    end

    test "persisted offer pricing and terms are immutable" do
      offer = build_offer(code: "immutable_#{SecureRandom.hex(4)}")
      offer.save!
      offer.daily_rate_minor += 1

      assert_not offer.valid?
      assert_includes offer.errors.attribute_names, :daily_rate_minor
    end

    private

    def build_offer(**overrides)
      PlacementOffer.new({
        code: "public_discovery", version: 1, daily_rate_minor: 100_000, currency: "ETB",
        minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", status: "active",
        created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
        idempotency_key_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
        request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      }.merge(overrides))
    end
  end
end
