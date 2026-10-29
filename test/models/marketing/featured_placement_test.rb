# frozen_string_literal: true

require "test_helper"

module Marketing
  class FeaturedPlacementTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @offer = PlacementOffer.create!(
        code: "public_discovery", version: 1, daily_rate_minor: 100_000, currency: "ETB",
        minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", status: "active",
        created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
        idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      )
    end

    test "accepts a complete pending placement snapshot scoped to the event organization" do
      placement = build_placement

      assert_predicate placement, :valid?, placement.errors.full_messages.join(", ")
    end

    test "rejects a placement whose organization does not own its event" do
      placement = build_placement(organization: organizations_organizations(:one))

      assert_not placement.valid?
      assert_includes placement.errors.attribute_names, :organization_id
    end

    test "keeps the purchased interval and price snapshot immutable after creation" do
      placement = build_placement
      placement.save!
      placement.update!(status: "scheduled")
      placement.starts_at += 1.hour

      assert_not placement.valid?
      assert_includes placement.errors.attribute_names, :starts_at
    end

    private

    def build_placement(organization: Organizations::Organization.find(@event.organization_id))
      duration = 3.days.to_i
      rate = @offer.daily_rate_minor
      starts_at = Events::EventDate.where(event_id: @event.id).minimum(:starts_at) || 7.days.from_now
      Marketing::FeaturedPlacement.new(
        event: @event, organization:, placement_offer: @offer, status: "pending_payment",
        starts_at:, ends_at: starts_at + duration,
        duration_seconds: duration, surface: @offer.surface, offer_code: @offer.code,
        offer_version: @offer.version, daily_rate_minor: rate, amount_minor: (rate * duration + 86_399) / 86_400,
        currency: @offer.currency, terms_version: @offer.terms_version,
        price_digest: "a" * 64, idempotency_key_digest: "b" * 64, request_digest: "c" * 64
      )
    end
  end
end
