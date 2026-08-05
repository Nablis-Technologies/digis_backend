# frozen_string_literal: true

require "test_helper"

module Catalog
  module Promotions
    class DeleteDraftTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @promotion = Catalog::Promotion.create!(
          event: @event,
          name: "Opening discount",
          type: "fixed",
          fixed_amount_minor: 500,
          currency: "ETB",
          status: "draft",
          per_user_limit: 1
        )
      end

      test "deletes a draft promotion" do
        result = DeleteDraft.call(
          promotion: @promotion,
          actor: @actor,
          idempotency_key: "promotion-delete-1"
        )

        assert result.success?, result.error&.message
        assert_not Catalog::Promotion.exists?(@promotion.id)
      end

      test "rejects deleting an active promotion" do
        @promotion.update!(status: "active")

        result = DeleteDraft.call(
          promotion: @promotion,
          actor: @actor,
          idempotency_key: "promotion-delete-active"
        )

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end

      test "rejects deleting a disabled promotion" do
        @promotion.update!(status: "disabled")

        result = DeleteDraft.call(
          promotion: @promotion,
          actor: @actor,
          idempotency_key: "promotion-delete-disabled"
        )

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end
    end
  end
end
