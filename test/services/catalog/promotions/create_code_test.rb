# frozen_string_literal: true

require "test_helper"

module Catalog
  module Promotions
    class CreateCodeTest < ActiveSupport::TestCase
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

      test "stores a canonical encrypted code and returns plaintext once" do
        result = CreateCode.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { code: " save10 ", label: "Opening" },
          idempotency_key: "promotion-code-1"
        )

        assert result.success?, result.error&.message
        assert_equal "SAVE10", result.value.plaintext
        assert_equal "SAVE10", result.value.record.code
        assert_not_equal "SAVE10", result.value.record.code_ciphertext_before_type_cast
      end

      test "rejects duplicate canonical codes" do
        first = CreateCode.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { code: "SAVE10" },
          idempotency_key: "promotion-code-2"
        )
        duplicate = CreateCode.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { code: " save10 " },
          idempotency_key: "promotion-code-3"
        )

        assert first.success?
        assert duplicate.failure?
        assert_match(/already exists/i, duplicate.error.message)
      end

      test "rejects code creation for a disabled promotion" do
        @promotion.update!(status: "disabled")

        result = CreateCode.call(
          promotion: @promotion,
          actor: @actor,
          attributes: { code: "SAVE10" },
          idempotency_key: "promotion-code-4"
        )

        assert result.failure?
        assert_match(/promotion/i, result.error.message)
      end
    end
  end
end
