# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  module FeaturedPlacements
    class PublicQueryTest < ActiveSupport::TestCase
      include Marketing::FeaturedPlacementTestHelpers

      setup do
        @event = events_events(:ready_listing)
        Core::Review.create!(reviewable: @event.organization, context: "verification", status: "approved")
        make_publishable(@event)
        Events::EventDate.where(event_id: @event.id).update_all(
          status: "scheduled", starts_at: 52.hours.from_now, ends_at: 54.hours.from_now
        )
        @event.event_setting.update!(config: { event_type: "rsvp", public_guest_limit: 10 })
        Events::Publish.call(event: @event, actor: core_users(:super_admin), idempotency_key: SecureRandom.uuid)
        create_active_free_ticket
        @doors_at = Events::EventDate.where(event_id: @event.id, status: "scheduled").minimum(:starts_at)
        @offer = PlacementOffer.create!(
          code: "public_query_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 10_000,
          currency: "ETB", minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", status: "active",
          created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        @capacity_policy = create_active_capacity_policy!(max_concurrent: 4)
        @placement, @purchase, @payment = create_paid_serving_placement
      end

      test "serves a paid, current placement with the shared public availability projection" do
        result = PublicQuery.call(at: Time.current)

        assert_predicate result, :success?, result.error&.message
        assert_equal [ @placement.id ], result.value.placements.map(&:id)
        assert_equal [ @event.id ], result.value.event_ids
        assert_equal "available", result.value.event_statuses.dig(@event.id, :ticket_availability)
        assert_equal "upcoming", result.value.event_statuses.dig(@event.id, :event_lifecycle)
      end

      test "excludes unpaid, private, and closed-registration events" do
        @purchase.update!(status: "pending_payment")
        assert_empty PublicQuery.call.value.placements

        @purchase.update!(status: "paid")
        @event.update!(visibility: "private")
        assert_empty PublicQuery.call.value.placements
      end

      test "keeps serving paid placements when no admission capacity policy exists" do
        retire_capacity_policy_for_test!(@capacity_policy)

        result = PublicQuery.call

        assert_predicate result, :success?, result.error&.message
        assert_equal [ @placement.id ], result.value.placements.map(&:id)
      end

      test "does not truncate paid placements to a lower admission cap" do
        event_class = Struct.new(:id)
        candidate_class = Struct.new(:event_id, :event)
        placements = %w[event-1 event-2].map do |event_id|
          candidate_class.new(event_id, event_class.new(event_id))
        end
        statuses = placements.to_h { |placement| [ placement.event_id, { ticket_availability: "available" } ] }
        query = PublicQuery.new(at: Time.current)
        query.define_singleton_method(:serving_placements) { |limit:| placements }
        Catalog::Public::EventAvailabilitySummary.stubs(:call).returns(statuses)

        result = query.call

        assert_predicate result, :success?, result.error&.message
        assert_equal %w[event-1 event-2], result.value.event_ids.sort
      end

      test "filters unavailable candidates before applying the public response limit" do
        event_class = Struct.new(:id)
        candidate_class = Struct.new(:event_id, :event)
        placements = (PublicQuery::MAX_FETCH_SIZE + 1).times.map do |index|
          event_id = "eligible-event-#{index}"
          candidate_class.new(event_id, event_class.new(event_id))
        end
        statuses = placements.to_h do |placement|
          availability = placement.event_id == "eligible-event-0" ? "sold_out" : "available"
          [ placement.event_id, { ticket_availability: availability } ]
        end
        requests = []
        query = PublicQuery.new(at: Time.current)
        query.define_singleton_method(:serving_placements) do |limit:, offset: 0|
          requests << { limit:, offset: }
          offset.zero? ? placements.first(limit) : []
        end
        Catalog::Public::EventAvailabilitySummary.stubs(:call).returns(statuses)

        result = query.call

        assert_predicate result, :success?, result.error&.message
        assert_equal PublicQuery::MAX_FETCH_SIZE, result.value.placements.length
        assert_equal [ { limit: PublicQuery::MAX_FETCH_SIZE + 2, offset: 0 } ], requests
      end

      test "fails safely with one bounded read when candidates exceed the scan" do
        event_class = Struct.new(:id)
        candidate_class = Struct.new(:event_id, :event)
        placements = (PublicQuery::MAX_FETCH_SIZE + 2).times.map do |index|
          event_id = "bounded-event-#{index}"
          candidate_class.new(event_id, event_class.new(event_id))
        end
        statuses = placements.to_h do |placement|
          availability = placement.event_id == "bounded-event-0" ? "sold_out" : "available"
          [ placement.event_id, { ticket_availability: availability } ]
        end
        requests = []
        query = PublicQuery.new(at: Time.current)
        query.define_singleton_method(:serving_placements) do |limit:, offset: 0|
          requests << { limit:, offset: }
          offset.zero? ? placements.first(limit) : placements.drop(offset).first(limit)
        end
        Catalog::Public::EventAvailabilitySummary.stubs(:call).returns(statuses)

        result = query.call

        assert_predicate result, :failure?
        assert_equal "featured_events_unavailable", result.error.code
        assert_equal [ { limit: PublicQuery::MAX_FETCH_SIZE + 2, offset: 0 } ], requests
      end

      test "fails safely rather than truncating paid candidates beyond the hard serving bound" do
        candidate_class = Struct.new(:event_id, :event)
        event_class = Struct.new(:id)
        placements = (PublicQuery::MAX_FETCH_SIZE + 1).times.map do |index|
          event_id = "event-#{index}"
          candidate_class.new(event_id, event_class.new(event_id))
        end
        statuses = placements.to_h { |placement| [ placement.event_id, { ticket_availability: "available" } ] }
        query = PublicQuery.new(at: Time.current)
        requested_limit = nil
        query.define_singleton_method(:serving_placements) do |limit:|
          requested_limit = limit
          placements
        end
        Catalog::Public::EventAvailabilitySummary.stubs(:call).returns(statuses)

        result = query.call

        assert_predicate result, :failure?
        assert_equal "featured_events_unavailable", result.error.code
        assert_equal PublicQuery::MAX_FETCH_SIZE + 2, requested_limit
      end

      private

      def create_paid_serving_placement
        starts_at = Time.current.utc.change(usec: 0) - 1.hour
        ends_at = @doors_at
        duration = (ends_at - starts_at).to_i
        price = (@offer.daily_rate_minor * duration + 86_399) / 86_400
        price_digest = Digest::SHA256.hexdigest("public-placement-price")
        placement = Marketing::FeaturedPlacement.create!(
          event: @event, organization_id: @event.organization_id, placement_offer: @offer,
          status: "active", surface: "public_discovery", starts_at:, ends_at:, duration_seconds: duration,
          offer_code: @offer.code, offer_version: @offer.version, daily_rate_minor: @offer.daily_rate_minor,
          amount_minor: price, currency: "ETB", terms_version: @offer.terms_version, price_digest:,
          idempotency_key_digest: Digest::SHA256.hexdigest("public-placement-#{SecureRandom.uuid}"),
          request_digest: Digest::SHA256.hexdigest("public-request-#{SecureRandom.uuid}")
        )
        purchase = Orders::BillingPurchase.create!(
          organization_id: @event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
          currency: "ETB", amount_minor: price, price_digest:, status: "paid",
          idempotency_key_digest: Digest::SHA256.hexdigest("public-purchase-#{SecureRandom.uuid}"),
          expires_at: 30.minutes.from_now
        )
        payment = Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: price, currency: "ETB", accepted_at: Time.current,
          succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "public-payment-#{SecureRandom.hex(4)}",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )
        [ placement, purchase, payment ]
      end

      def create_active_free_ticket
        product = Catalog::Products::CreateDraft.call(
          event: @event, actor: core_users(:super_admin),
          product_attributes: { name: "Public featured RSVP", type: "ticket" },
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
