# frozen_string_literal: true

require "test_helper"

module Catalog
  module Promotions
    class LifecycleTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
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

      test "publishes a draft promotion" do
        result = PublishVersion.call(
          promotion: @promotion,
          actor: @actor,
          idempotency_key: "promotion-publish-1"
        )

        assert result.success?, result.error&.message
        assert_equal "active", @promotion.reload.status
      end

      test "publishing the same version twice is audit-idempotent" do
        assert_audit_idempotent(
          -> {
            PublishVersion.call(
              promotion: @promotion,
              actor: @actor,
              idempotency_key: "promotion-publish-2"
            )
          },
          action: "catalog.promotion.published",
          auditable_type: "Catalog::Promotion",
          auditable_id: @promotion.id
        )
      end

      test "publishing a superseding version disables the previous active version" do
        @promotion.update!(status: "active")
        replacement = Catalog::Promotion.create!(
          event: @event,
          name: "Opening discount v2",
          type: "percentage",
          percentage_basis_points: 1_500,
          currency: "ETB",
          status: "draft",
          per_user_limit: 1,
          version: @promotion.version + 1,
          supersedes_promotion: @promotion
        )

        result = PublishVersion.call(
          promotion: replacement,
          actor: @actor,
          idempotency_key: "promotion-publish-3"
        )

        assert result.success?, result.error&.message
        assert_equal "active", replacement.reload.status
        assert_equal "disabled", @promotion.reload.status
      end

      test "disables an active promotion and is idempotent when repeated" do
        @promotion.update!(status: "active")

        first = Disable.call(
          promotion: @promotion,
          actor: @actor,
          idempotency_key: "promotion-disable-1"
        )
        second = Disable.call(
          promotion: @promotion,
          actor: @actor,
          idempotency_key: "promotion-disable-2"
        )

        assert first.success?
        assert second.success?
        assert_equal "disabled", @promotion.reload.status
      end

      test "cannot publish a disabled promotion" do
        @promotion.update!(status: "disabled")

        result = PublishVersion.call(
          promotion: @promotion,
          actor: @actor,
          idempotency_key: "promotion-publish-disabled"
        )

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end
    end
  end
end
