# frozen_string_literal: true

require "test_helper"

module Catalog
  module Products
    class LifecycleTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @other_event = events_events(:draft_concert)
        @actor = core_users(:super_admin)
      end

      test "create replay is scoped to the event and requires the same request" do
        key = "catalog-create-#{SecureRandom.uuid}"

        first = create_draft(event: @event, name: "Festival Pass", idempotency_key: key)
        replay = create_draft(event: @event, name: "Festival Pass", idempotency_key: key)
        conflict = create_draft(event: @event, name: "Different Product", idempotency_key: key)
        other_event = create_draft(event: @other_event, name: "Other Event Pass", idempotency_key: key)

        assert first.success?
        assert replay.success?
        assert_equal first.value.id, replay.value.id
        assert conflict.failure?
        assert_match(/different request/i, conflict.error.message)
        assert other_event.success?
        refute_equal first.value.id, other_event.value.id
      end

      test "create stores digests rather than the raw idempotency key" do
        raw_key = " secret-client-key "

        result = create_draft(event: @event, name: "Digest Pass", idempotency_key: raw_key)

        assert result.success?
        product = result.value.reload
        assert_equal Digest::SHA256.hexdigest(raw_key.strip), product.idempotency_key_digest
        assert_match(/\A[0-9a-f]{64}\z/, product.creation_request_digest)
        refute_includes product.attributes.values, raw_key
        refute_includes product.attributes.values, raw_key.strip
      end

      test "invalid idempotency key returns a service failure" do
        result = create_draft(
          event: @event,
          name: "Invalid Key Pass",
          idempotency_key: "x" * 256
        )

        assert result.failure?
        assert_match(/exceeds 255 bytes/i, result.error.message)
      end

      test "creation writes one atomic audit record across a replay" do
        key = "catalog-audit-#{SecureRandom.uuid}"
        product_id = nil
        operation = lambda do
          create_draft(event: @event, name: "Audited Pass", idempotency_key: key).tap do |result|
            product_id ||= result.value&.id
          end
        end

        assert_audit_idempotent(
          operation,
          action: "catalog.product.created",
          auditable_type: "Catalog::EventProduct",
          auditable_id: -> { product_id }
        )
      end

      test "activation is idempotent and accepts a price active at the scheduled sales start" do
        sales_start = 2.days.from_now
        created = create_draft(
          event: @event,
          name: "Scheduled Pass",
          product_attributes: { sales_start_at: sales_start },
          price_attributes: {
            type: "base",
            currency: "ETB",
            amount_minor: 1_000,
            active_from: sales_start
          }
        )
        assert created.success?

        first = Activate.call(product: created.value, actor: @actor)
        replay = Activate.call(product: created.value.reload, actor: @actor)

        assert first.success?
        assert replay.success?
        assert_equal "active", created.value.reload.status
      end

      test "only active products can be retired and retirement is idempotent" do
        draft = create_draft(event: @event, name: "Draft Pass").value

        invalid = Deactivate.call(product: draft, actor: @actor)
        assert invalid.failure?
        assert_equal "draft", draft.reload.status

        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        assert Activate.call(product: draft, actor: @actor).success?

        first = Deactivate.call(product: draft.reload, actor: @actor)
        replay = Deactivate.call(product: draft.reload, actor: @actor)

        assert first.success?
        assert replay.success?
        assert_equal "retired", draft.reload.status
      end

      test "activation rejects a product with unzoned venue access when zones are enabled" do
        draft = create_draft(event: @event, name: "Zoned Pass").value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                         ends_at: 1.day.from_now + 4.hours)
        Events::AccessZone.create!(event: @event, event_date: date, code: "MAIN",
                                   name: "Main Gate", type: "venue", sort_order: 0)
        draft.product_accesses.create!(event_date: date, type: "venue", usage_limit: 1)

        result = Activate.call(product: draft, actor: @actor)

        assert result.failure?
        assert_match(/zone grant/i, result.error.message)
        assert_equal "draft", draft.reload.status
      end

      test "activation succeeds when zoned venue access has an explicit zone grant" do
        draft = create_draft(event: @event, name: "Granted Pass").value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                         ends_at: 1.day.from_now + 4.hours)
        zone = Events::AccessZone.create!(event: @event, event_date: date, code: "VIP",
                                          name: "VIP Gate", type: "venue", sort_order: 0)
        access = draft.product_accesses.create!(event_date: date, type: "venue", usage_limit: 1)
        access.product_access_zones.create!(access_zone: zone)

        result = Activate.call(product: draft, actor: @actor)

        assert result.success?, result.error&.message
        assert_equal "active", draft.reload.status
      end

      test "activation batches active zone lookup for multiple accesses" do
        draft = create_draft(event: @event, name: "Multi Access Pass").value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                         ends_at: 1.day.from_now + 4.hours)
        venue_zone = Events::AccessZone.create!(event: @event, event_date: date,
                                                code: "VENUE", name: "Venue Gate",
                                                type: "venue", sort_order: 0)
        parking_zone = Events::AccessZone.create!(event: @event, event_date: date,
                                                  code: "PARKING", name: "Parking",
                                                  type: "parking", sort_order: 1)
        venue_access = draft.product_accesses.create!(event_date: date, type: "venue")
        parking_access = draft.product_accesses.create!(event_date: date, type: "parking")
        venue_access.product_access_zones.create!(access_zone: venue_zone)
        parking_access.product_access_zones.create!(access_zone: parking_zone)

        result = Activate.call(product: draft, actor: @actor)

        assert result.success?, result.error&.message
        assert_equal "active", draft.reload.status
      end

      test "activation rejects a multi-date fixed product without date allocations" do
        draft = create_draft(event: @event, name: "Alloc Gate Pass").value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date_one = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                             ends_at: 1.day.from_now + 4.hours)
        date_two = Events::EventDate.create!(event: @event, starts_at: 2.days.from_now,
                                             ends_at: 2.days.from_now + 4.hours)
        draft.product_accesses.create!(event_date: date_one, type: "venue")
        draft.product_accesses.create!(event_date: date_two, type: "venue")

        result = Activate.call(product: draft, actor: @actor)

        assert result.failure?
        assert_match(/allocation/i, result.error.message)
        assert_equal "draft", draft.reload.status
      end

      test "activation succeeds when allocations cover every granted date" do
        draft = create_draft(event: @event, name: "Alloc Covered Pass").value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date_one = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                             ends_at: 1.day.from_now + 4.hours)
        date_two = Events::EventDate.create!(event: @event, starts_at: 2.days.from_now,
                                             ends_at: 2.days.from_now + 4.hours)
        draft.product_accesses.create!(event_date: date_one, type: "venue")
        draft.product_accesses.create!(event_date: date_two, type: "venue")
        draft.product_date_allocations.create!(event_date: date_one, allocation_basis_points: 5_000)
        draft.product_date_allocations.create!(event_date: date_two, allocation_basis_points: 5_000)

        result = Activate.call(product: draft, actor: @actor)

        assert result.success?, result.error&.message
        assert_equal "active", draft.reload.status
      end

      test "activation rejects a multi-date product with partial allocation coverage" do
        draft = create_draft(event: @event, name: "Partial Alloc Pass").value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date_one = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                             ends_at: 1.day.from_now + 4.hours)
        date_two = Events::EventDate.create!(event: @event, starts_at: 2.days.from_now,
                                             ends_at: 2.days.from_now + 4.hours)
        date_three = Events::EventDate.create!(event: @event, starts_at: 3.days.from_now,
                                               ends_at: 3.days.from_now + 4.hours)
        draft.product_accesses.create!(event_date: date_one, type: "venue")
        draft.product_accesses.create!(event_date: date_two, type: "venue")
        draft.product_accesses.create!(event_date: date_three, type: "venue")
        draft.product_date_allocations.create!(event_date: date_one, allocation_basis_points: 10_000)

        result = Activate.call(product: draft, actor: @actor)

        assert result.failure?
        assert_match(/allocation/i, result.error.message)
        assert_equal "draft", draft.reload.status
      end

      test "activation succeeds for a single-date product without allocations" do
        draft = create_draft(event: @event, name: "Single Date Pass").value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                         ends_at: 1.day.from_now + 4.hours)
        draft.product_accesses.create!(event_date: date, type: "venue")

        result = Activate.call(product: draft, actor: @actor)

        assert result.success?, result.error&.message
        assert_equal "active", draft.reload.status
      end

      test "activation succeeds for a choose_one ticket product without allocations" do
        created = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name: "Pick A Day Pass", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "choose_one",
            admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor: 1_000, active_from: 1.hour.ago },
          inventory_configuration: { mode: "unlimited" }
        )
        assert created.success?, created.error&.message
        draft = created.value
        date_one = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                             ends_at: 1.day.from_now + 4.hours)
        date_two = Events::EventDate.create!(event: @event, starts_at: 2.days.from_now,
                                             ends_at: 2.days.from_now + 4.hours)
        draft.product_accesses.create!(event_date: date_one, type: "venue")
        draft.product_accesses.create!(event_date: date_two, type: "venue")

        result = Activate.call(product: draft, actor: @actor)

        assert result.success?, result.error&.message
        assert_equal "active", draft.reload.status
      end

      test "activation succeeds for a full_only multi-date product without allocations" do
        draft = create_draft(
          event: @event,
          name: "Full Only Pass",
          product_attributes: { schedule_change_refund_policy: "full_only" }
        ).value
        Catalog::ProductPrice.create!(
          event_product: draft,
          type: "base",
          currency: "ETB",
          amount_minor: 1_000,
          active_from: 1.hour.ago
        )
        date_one = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                             ends_at: 1.day.from_now + 4.hours)
        date_two = Events::EventDate.create!(event: @event, starts_at: 2.days.from_now,
                                             ends_at: 2.days.from_now + 4.hours)
        draft.product_accesses.create!(event_date: date_one, type: "venue")
        draft.product_accesses.create!(event_date: date_two, type: "venue")

        result = Activate.call(product: draft, actor: @actor)

        assert result.success?, result.error&.message
        assert_equal "active", draft.reload.status
      end

      private

      def create_draft(event:, name:, idempotency_key: nil, product_attributes: {}, price_attributes: nil)
        CreateDraft.call(
          event:,
          actor: @actor,
          product_attributes: {
            name:,
            type: "merchandise"
          }.merge(product_attributes),
          price_attributes:,
          inventory_configuration: { mode: "unlimited" },
          idempotency_key:
        )
      end
    end
  end
end
