# frozen_string_literal: true

require "test_helper"

module Marketing
  module FeaturedPlacements
    class CreateTest < ActiveSupport::TestCase
      include Marketing::FeaturedPlacementTestHelpers

      class FakeAdapter < Payments::Providers::Adapter
        attr_reader :create_calls

        def initialize
          @create_calls = []
        end

        def create(**arguments)
          @create_calls << arguments
          Payments::Providers::Result.unknown(
            provider_reference: "featured-checkout", checkout_url: "https://checkout.test/featured"
          )
        end
        def cancel(**) = Payments::Providers::Result.cancelled
        def verify(**) = Payments::Providers::Result.unknown
        def refund(**) = Payments::Providers::Result.unknown
        def verify_refund(**) = Payments::Providers::Result.unknown
        def merchant_reference(subject_id:, idempotency_key:, attempt_number:) = "featured-ref-#{attempt_number}"
        def available_balance(**) = { amount_minor: 1_000_000, currency: "ETB" }
        def capabilities = { currencies: [ "ETB" ], payment_methods: [ "telebirr" ] }
        def settlement_grace_minutes = 5
      end

      setup do
        @previous_enabled = Rails.application.config.x.marketing_featured_placements_enabled
        @event = events_events(:ready_listing)
        @purchaser = core_users(:super_admin)
        Core::Review.create!(reviewable: @event.organization, context: "verification", status: "approved")
        make_publishable(@event)
        Events::EventDate.where(event_id: @event.id).update_all(
          status: "scheduled", starts_at: 52.hours.from_now, ends_at: 54.hours.from_now
        )
        @event.event_setting.update!(config: { event_type: "rsvp", public_guest_limit: 10 })
        Events::Publish.call(event: @event, actor: @purchaser, idempotency_key: SecureRandom.uuid)
        create_active_public_ticket
        @doors_at = Events::EventDate.where(event_id: @event.id, status: "scheduled").minimum(:starts_at)
        @offer = PlacementOffer.create!(
          code: "public_discovery", version: 1, daily_rate_minor: 100_001, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", status: "active",
          created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        @capacity_policy = create_active_capacity_policy!(max_concurrent: 3)
        Rails.application.config.x.marketing_featured_placements_enabled = true
        @adapter = FakeAdapter.new
        Payments::Providers::Registry.register("chapa", @adapter)
      end

      teardown do
        Payments::Providers::Registry.instance_variable_set(:@adapters, {})
        Rails.application.config.x.marketing_featured_placements_enabled = @previous_enabled
      end

      test "creates an idempotent billing purchase without an event order or ticket" do
        operation = -> { create(idempotency_key: "featured-placement-create") }
        assert_idempotent(operation, counter: -> { FeaturedPlacement.count })
        first = operation.call

        assert_predicate first, :success?, first.error&.message
        placement = first.value.placement
        assert_equal "pending_payment", placement.status
        assert_equal "pending_payment", first.value.billing_purchase.status
        assert_equal "Marketing::FeaturedPlacement", first.value.billing_purchase.source_type
        assert_equal placement.id, first.value.billing_purchase.source_id
        assert_equal 1, @adapter.create_calls.length
        assert_equal "https://checkout.test/featured", first.value.payment.checkout_url
        assert_equal 0, Orders::Order.where(event_id: @event.id).count
      end

      test "writes one creation audit for repeated idempotent submissions" do
        placement_id = nil
        operation = lambda do
          result = create(idempotency_key: "featured-placement-audit")
          placement_id ||= result.value&.placement&.id
          result
        end
        assert_audit_idempotent(
          operation, action: "marketing.featured_placement.created", auditable_type: "Marketing::FeaturedPlacement",
          auditable_id: -> { placement_id || "00000000-0000-7000-8000-000000000000" }
        )
        assert_equal 1, Core::AuditLog.where(action: "marketing.featured_placement.created", auditable_id: placement_id).count
        assert_equal 1, @adapter.create_calls.length
      end

      test "rejects a changed schedule under the same idempotency key" do
        first = create(idempotency_key: "featured-placement-conflict", starts_at: @doors_at - 50.hours)
        second = create(idempotency_key: "featured-placement-conflict", starts_at: @doors_at - 49.hours)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 1, FeaturedPlacement.count
      end

      test "recovers a paid replay from accepted payment evidence instead of starting a closed checkout" do
        first = create(idempotency_key: "featured-placement-accepted-replay")
        assert_predicate first, :success?, first.error&.message
        first.value.payment.update!(status: "succeeded", succeeded_at: Time.current, accepted_at: Time.current)
        first.value.billing_purchase.update!(status: "paid")

        replay = create(idempotency_key: "featured-placement-accepted-replay")

        assert_predicate replay, :success?, replay.error&.message
        assert replay.value.replayed
        assert_equal "scheduled", replay.value.placement.status
        assert_equal 1, @adapter.create_calls.length
      end

      test "rejects a non-owner and non-admin before reserving capacity or dispatching payment" do
        result = Create.call(
          event: @event, purchaser: core_users(:attendee), offer_id: @offer.id,
          starts_at: @doors_at - 50.hours, idempotency_key: "featured-placement-forbidden"
        )

        assert_predicate result, :failure?
        assert_equal "purchase_forbidden", result.error.code
        assert_empty FeaturedPlacement.all
        assert_empty @adapter.create_calls
      end

      test "rechecks the per-surface cap before creating or calling the provider" do
        replace_active_capacity_policy!(max_concurrent: 1)
        create_placement(status: "scheduled", starts_at: @doors_at - 50.hours)

        result = create(idempotency_key: "featured-placement-sold-out")

        assert_predicate result, :failure?
        assert_equal "capacity_full", result.error.code
        assert_equal :conflict, result.error.status
        assert_equal 1, FeaturedPlacement.count
        assert_empty @adapter.create_calls
      end

      test "serializes concurrent purchases across different request keys without overselling the surface" do
        replace_active_capacity_policy!(max_concurrent: 1)

        race = run_database_race(worker_count: 2) do |index|
          Create.call(
            event: Events::Event.find(@event.id), purchaser: Core::User.find(@purchaser.id),
            offer_id: @offer.id, starts_at: @doors_at - 50.hours,
            idempotency_key: "featured-cap-race-#{index}"
          )
        end

        assert_empty race.errors
        assert_equal 1, race.results.count(&:success?)
        assert_equal 1, race.results.count(&:failure?)
        assert_equal "capacity_full", race.results.find(&:failure?).error.code
        assert_equal 1, FeaturedPlacement.where(status: "pending_payment").count
        assert_equal 1, @adapter.create_calls.length
      end

      private

      def create(idempotency_key:, starts_at: @doors_at - 50.hours)
        Create.call(
          event: @event, purchaser: @purchaser, offer_id: @offer.id,
          starts_at:, idempotency_key:
        )
      end

      def create_placement(status:, starts_at:)
        ends_at = @doors_at
        duration = (ends_at - starts_at).to_i
        FeaturedPlacement.create!(
          event: @event, organization_id: @event.organization_id, placement_offer: @offer, status:,
          surface: @offer.surface, starts_at:, ends_at:, duration_seconds: duration,
          offer_code: @offer.code, offer_version: @offer.version, daily_rate_minor: @offer.daily_rate_minor,
          amount_minor: (@offer.daily_rate_minor * duration + 86_399) / 86_400,
          currency: @offer.currency, terms_version: @offer.terms_version,
          price_digest: "d" * 64, idempotency_key_digest: "e" * 64, request_digest: "f" * 64
        )
      end

      def create_active_public_ticket
        product = Catalog::Products::CreateDraft.call(
          event: @event, actor: @purchaser,
          product_attributes: { name: "Featured create ticket", type: "ticket" },
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
        Catalog::Products::Activate.call(product:, actor: @purchaser)
      end
    end
  end
end
