# frozen_string_literal: true

require "test_helper"

module Catalog
  module Promotions
    class CreateTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @other_event = events_events(:draft_concert)
        @product = Catalog::EventProduct.create!(
          event: @event,
          name: "Festival Pass",
          type: "merchandise",
          status: "draft",
          inventory_mode: "unlimited"
        )
        @other_product = Catalog::EventProduct.create!(
          event: @other_event,
          name: "Other Pass",
          type: "merchandise",
          status: "draft",
          inventory_mode: "unlimited"
        )
        @actor = core_users(:super_admin)
      end

      test "creates a version one draft with an optional product scope" do
        result = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes,
          product_ids: [ @product.id ],
          idempotency_key: "promotion-create-1"
        )

        assert result.success?, result.error&.message
        promotion = result.value
        assert_equal 1, promotion.version
        assert_equal "draft", promotion.status
        assert_equal [ @product.id ], promotion.event_products.pluck(:id)
      end

      test "rejects a product from another event without mutation" do
        result = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes,
          product_ids: [ @other_product.id ],
          idempotency_key: "promotion-create-2"
        )

        assert result.failure?
        assert_equal 0, Catalog::Promotion.count
        assert_match(/same event/i, result.error.message)
      end

      test "rejects scalar product ids without mutation" do
        before_count = Catalog::Promotion.count

        result = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes,
          product_ids: @product.id,
          idempotency_key: "promotion-create-scalar-product-id"
        )

        assert result.failure?
        assert_equal I18n.t("catalog.promotion.errors.invalid_product_ids"), result.error.message
        assert_equal before_count, Catalog::Promotion.count
      end

      test "links a new draft to the next version of its predecessor" do
        first = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes,
          idempotency_key: "promotion-create-3"
        ).value

        second = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes.merge(supersedes_promotion_id: first.id),
          idempotency_key: "promotion-create-4"
        ).value

        assert_equal first.id, second.supersedes_promotion_id
        assert_equal first.version + 1, second.version
      end

      test "rejects a predecessor from another event" do
        other = Create.call(
          event: @other_event,
          actor: @actor,
          attributes: percentage_attributes,
          idempotency_key: "promotion-create-other-event"
        ).value

        result = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes.merge(supersedes_promotion_id: other.id),
          idempotency_key: "promotion-create-cross-event"
        )

        assert result.failure?
        assert_equal 0, Catalog::Promotion.where(event_id: @event.id).count
      end

      test "replaying the same request does not create a second promotion" do
        subject = lambda do
          Create.call(
            event: @event,
            actor: @actor,
            attributes: percentage_attributes,
            idempotency_key: "promotion-create-replay"
          )
        end

        assert_idempotent(subject, counter: -> { Catalog::Promotion.count })
      end

      test "rejects an idempotency key reused for a different request" do
        key = "promotion-create-conflict"
        first = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes,
          idempotency_key: key
        )
        second = Create.call(
          event: @event,
          actor: @actor,
          attributes: percentage_attributes.merge(name: "Different"),
          idempotency_key: key
        )

        assert first.success?
        assert second.failure?
        assert_match(/different request/i, second.error.message)
      end

      private

      def percentage_attributes
        {
          name: "Opening discount",
          type: "percentage",
          percentage_basis_points: 1_000,
          currency: "ETB",
          per_user_limit: 1
        }
      end
    end
  end
end
