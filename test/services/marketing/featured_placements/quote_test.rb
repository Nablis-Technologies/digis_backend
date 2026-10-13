# frozen_string_literal: true

require "test_helper"

module Marketing
  module FeaturedPlacements
    class QuoteTest < ActiveSupport::TestCase
      setup do
        @previous_capacity = Rails.application.config.x.marketing_featured_max_concurrent_by_surface
        @previous_enabled = Rails.application.config.x.marketing_featured_placements_enabled
        @event = events_events(:ready_listing)
        Core::Review.create!(reviewable: @event.organization, context: "verification", status: "approved")
        make_publishable(@event)
        Events::EventDate.where(event_id: @event.id).update_all(
          status: "scheduled", starts_at: 52.hours.from_now, ends_at: 52.hours.from_now + 2.hours
        )
        @event.event_setting.update!(config: { event_type: "rsvp", public_guest_limit: 10 })
        Events::Publish.call(event: @event, actor: core_users(:super_admin), idempotency_key: SecureRandom.uuid)
        create_active_public_ticket
        @doors_at = Events::EventDate.where(event_id: @event.id, status: "scheduled").minimum(:starts_at)
        @offer = PlacementOffer.create!(
          code: "public_discovery", version: 1, daily_rate_minor: 100_001, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", active: true,
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        Rails.application.config.x.marketing_featured_max_concurrent_by_surface = { "public_discovery" => 2 }
        Rails.application.config.x.marketing_featured_placements_enabled = true
      end

      teardown do
        Rails.application.config.x.marketing_featured_max_concurrent_by_surface = @previous_capacity
        Rails.application.config.x.marketing_featured_placements_enabled = @previous_enabled
      end

      test "quotes the event-derived doors time and rounds a 50-hour interval up in minor units" do
        starts_at = @doors_at - 50.hours

        result = Quote.call(event: @event, offer: @offer, starts_at:)

        assert_predicate result, :success?, result.error&.message
        quote = result.value
        assert_equal @doors_at.to_i, quote.ends_at.to_i
        assert_equal 50.hours.to_i, quote.duration_seconds
        assert_equal ((100_001 * 50 + 23) / 24), quote.amount_minor
        assert quote.capacity_available
      end

      test "rejects a placement shorter than the 24-hour minimum" do
        result = Quote.call(event: @event, offer: @offer, starts_at: @doors_at - 23.hours)

        assert_predicate result, :failure?
        assert_equal "invalid_schedule", result.error.code
      end

      test "accepts the exact 24-hour minimum and 14-day maximum when checkout lead time fits" do
        minimum = Quote.call(event: @event, offer: @offer, starts_at: @doors_at - 24.hours)
        future_doors = 15.days.from_now.change(usec: 0)
        Events::EventDate.where(event_id: @event.id).update_all(
          starts_at: future_doors, ends_at: future_doors + 2.hours
        )
        doors_at = Events::EventDate.where(event_id: @event.id, status: "scheduled").minimum(:starts_at)
        maximum = Quote.call(event: @event, offer: @offer, starts_at: doors_at - 14.days)

        assert_predicate minimum, :success?, minimum.error&.message
        assert_equal 24.hours.to_i, minimum.value.duration_seconds
        assert_predicate maximum, :success?, maximum.error&.message
        assert_equal 14.days.to_i, maximum.value.duration_seconds
        assert_equal 14 * 100_001, maximum.value.amount_minor
      end

      test "requires at least 60 minutes for hosted checkout to complete" do
        result = Quote.call(event: @event, offer: @offer, starts_at: Time.current + 59.minutes)

        assert_predicate result, :failure?
        assert_equal "invalid_schedule", result.error.code
      end

      test "fails closed when the surface capacity has no valid configuration" do
        Rails.application.config.x.marketing_featured_max_concurrent_by_surface = {}

        result = Quote.call(event: @event, offer: @offer, starts_at: @doors_at - 50.hours)

        assert_predicate result, :failure?
        assert_equal "capacity_unavailable", result.error.code
      end

      test "fails closed when the environment has not enabled featured placement sales" do
        Rails.application.config.x.marketing_featured_placements_enabled = false

        result = Quote.call(event: @event, offer: @offer, starts_at: @doors_at - 50.hours)

        assert_predicate result, :failure?
        assert_equal "feature_disabled", result.error.code
        assert_equal :service_unavailable, result.error.status
      end

      test "rejects an event that is no longer public" do
        @event.update!(visibility: "private")

        result = Quote.call(event: @event, offer: @offer, starts_at: @doors_at - 50.hours)

        assert_predicate result, :failure?
        assert_equal "event_ineligible", result.error.code
      end

      private

      def create_active_public_ticket
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Featured quote ticket", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor: 0, active_from: 1.hour.ago },
          inventory_configuration: { mode: "unlimited" }
        ).value
        product.product_accesses.create!(
          event_date_id: Events::EventDate.where(event_id: @event.id, status: "scheduled").pick(:id),
          type: "venue", usage_limit: nil
        )
        Catalog::Products::Activate.call(product:, actor: core_users(:super_admin))
      end
    end
  end
end
