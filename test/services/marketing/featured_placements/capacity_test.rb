# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  module FeaturedPlacements
    class CapacityTest < ActiveSupport::TestCase
      include Marketing::FeaturedPlacementTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @other_event = events_events(:draft_concert)
        @third_event = Events::Event.create!(
          organization_id: @event.organization_id, created_by_id: core_users(:super_admin).id,
          title: "Capacity sweep event", slug: "capacity-sweep-#{SecureRandom.hex(3)}",
          status: "draft", visibility: "private", timezone: "Africa/Addis_Ababa", currency: "ETB", version: 1
        )
        @offer = PlacementOffer.create!(
          code: "capacity_discovery", version: 1, daily_rate_minor: 10_000, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", status: "active",
          created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        @starts_at = Time.current.utc.change(usec: 0) + 1.hour
        @ends_at = @starts_at + 72.hours
        @capacity_policy = create_active_capacity_policy!(max_concurrent: 1)
      end

      test "uses half-open intervals so an immediately adjacent placement does not conflict" do
        existing = create_placement(event_id: @event.id, starts_at: @starts_at, ends_at: @starts_at + 24.hours)

        result = Capacity.call(
          event_id: @event.id, surface: "public_discovery", starts_at: existing.ends_at,
          ends_at: existing.ends_at + 24.hours
        )

        assert_predicate result, :success?, result.error&.message
        assert result.value.available
      end

      test "calculates the maximum concurrent overlap rather than counting any interval that intersects" do
        replace_active_capacity_policy!(max_concurrent: 2)
        create_placement(event_id: @event.id, starts_at: @starts_at, ends_at: @starts_at + 24.hours)
        create_placement(event_id: @other_event.id, starts_at: @starts_at + 24.hours, ends_at: @starts_at + 48.hours)

        result = Capacity.call(
          event_id: @third_event.id, surface: "public_discovery", starts_at: @starts_at, ends_at: @ends_at
        )

        assert_predicate result, :success?, result.error&.message
        assert result.value.available
      end

      test "uses the active database policy instead of the environment capacity value" do
        create_placement(event_id: @other_event.id, starts_at: @starts_at, ends_at: @starts_at + 24.hours)

        result = capacity_for(@event.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value.limit
        refute result.value.available
      end

      test "fails closed when overlapping active policy data violates the lifecycle invariant" do
        create_active_capacity_policy!(max_concurrent: 2)

        result = capacity_for(@event.id)

        assert_predicate result, :failure?
        assert_equal "capacity_unavailable", result.error.code
        assert_equal :service_unavailable, result.error.status
      end

      test "returns the earliest viable next start when same-event capacity is occupied" do
        existing = create_placement(
          event_id: @event.id, starts_at: @starts_at, ends_at: @starts_at + 24.hours
        )

        result = Capacity.call(
          event_id: @event.id, surface: "public_discovery", starts_at: @starts_at, ends_at: @ends_at
        )

        assert_predicate result, :success?, result.error&.message
        refute result.value.available
        assert_equal existing.ends_at, result.value.next_available_at
      end

      test "unexpired pending payment holds consume capacity and expired holds release it" do
        placement = create_placement(
          event_id: @other_event.id, starts_at: @starts_at, ends_at: @ends_at, status: "pending_payment"
        )
        purchase = Orders::BillingPurchase.create!(
          organization_id: @event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
          currency: "ETB", amount_minor: placement.amount_minor, price_digest: placement.price_digest,
          status: "pending_payment", idempotency_key_digest: Digest::SHA256.hexdigest("capacity-purchase"),
          expires_at: 30.minutes.from_now
        )

        held = capacity_for(@event.id)
        purchase.update!(expires_at: 1.minute.ago)
        released = capacity_for(@event.id)

        assert_predicate held, :success?
        refute held.value.available
        assert_predicate released, :success?
        assert released.value.available
      end

      private

      def capacity_for(event_id)
        Capacity.call(
          event_id:, surface: "public_discovery", starts_at: @starts_at, ends_at: @ends_at
        )
      end

      def create_placement(event_id:, starts_at:, ends_at:, status: "scheduled")
        duration = (ends_at - starts_at).to_i
        event = Events::Event.find(event_id)
        Marketing::FeaturedPlacement.create!(
          event:, organization_id: event.organization_id, placement_offer: @offer, status:,
          surface: "public_discovery", starts_at:, ends_at:, duration_seconds: duration,
          offer_code: @offer.code, offer_version: @offer.version, daily_rate_minor: @offer.daily_rate_minor,
          amount_minor: (@offer.daily_rate_minor * duration + 86_399) / 86_400,
          currency: "ETB", terms_version: @offer.terms_version,
          price_digest: Digest::SHA256.hexdigest("capacity-price-#{SecureRandom.uuid}"),
          idempotency_key_digest: Digest::SHA256.hexdigest("capacity-key-#{SecureRandom.uuid}"),
          request_digest: Digest::SHA256.hexdigest("capacity-request-#{SecureRandom.uuid}")
        )
      end
    end
  end
end
