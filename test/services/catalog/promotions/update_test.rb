# frozen_string_literal: true

require "test_helper"

module Catalog
  module Promotions
    class UpdateTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @product = Catalog::EventProduct.create!(
          event: @event,
          name: "Festival Pass",
          type: "merchandise",
          status: "draft",
          inventory_mode: "unlimited"
        )
        @second_product = Catalog::EventProduct.create!(
          event: @event,
          name: "VIP Pass",
          type: "merchandise",
          status: "draft",
          inventory_mode: "unlimited"
        )
        @actor = core_users(:super_admin)
        @promotion = Catalog::Promotion.create!(
          event: @event,
          name: "Opening discount",
          type: "percentage",
          percentage_basis_points: 1_000,
          currency: "ETB",
          status: "draft",
          per_user_limit: 1
        )
      end

      test "updates a draft and atomically replaces product scope" do
        result = Update.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { name: "Updated discount", percentage_basis_points: 2_000 },
          product_ids: [ @product.id, @second_product.id ],
          idempotency_key: "promotion-update-1"
        )

        assert result.success?, result.error&.message
        assert_equal "Updated discount", @promotion.reload.name
        assert_equal 2_000, @promotion.percentage_basis_points
        assert_equal [ @product.id, @second_product.id ].sort,
                     @promotion.event_products.pluck(:id).sort
      end

      test "preserves product scope when product_ids are omitted" do
        scoped = Update.call(
          promotion: @promotion,
          actor: @actor,
          attributes: {},
          product_ids: [ @product.id ],
          idempotency_key: "promotion-update-scope"
        )
        assert scoped.success?, scoped.error&.message

        result = Update.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { name: "Renamed discount" },
          idempotency_key: "promotion-update-name"
        )

        assert result.success?, result.error&.message
        assert_equal [ @product.id ], @promotion.reload.event_products.pluck(:id)
      end

      test "rejects scalar product ids without mutation" do
        result = Update.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { name: "Should not update" },
          product_ids: @product.id,
          idempotency_key: "promotion-update-scalar-product-id"
        )

        assert result.failure?
        assert_equal I18n.t("catalog.promotion.errors.invalid_product_ids"), result.error.message
        assert_equal "Opening discount", @promotion.reload.name
      end

      test "rejects updates to active promotions" do
        @promotion.update!(status: "active")

        result = update_promotion(idempotency_key: "promotion-update-active")

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end

      test "rejects updates to disabled promotions" do
        @promotion.update!(status: "disabled")

        result = update_promotion(idempotency_key: "promotion-update-disabled")

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end

      test "rejects a conflicting idempotency replay without mutation" do
        key = "promotion-update-conflict"
        first = Update.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { name: "First" },
          product_ids: [],
          idempotency_key: key
        )
        second = Update.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { name: "Second" },
          product_ids: [],
          idempotency_key: key
        )

        assert first.success?
        assert second.failure?
        assert_equal "First", @promotion.reload.name
      end

      private

      def update_promotion(idempotency_key:)
        Update.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { name: "No change" },
          product_ids: [],
          idempotency_key:
        )
      end
    end
  end
end
