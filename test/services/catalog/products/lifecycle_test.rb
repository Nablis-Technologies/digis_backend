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
