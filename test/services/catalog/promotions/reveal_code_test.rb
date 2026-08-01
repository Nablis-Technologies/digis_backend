# frozen_string_literal: true

require "test_helper"

module Catalog
  module Promotions
    class RevealCodeTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @promotion = Catalog::Promotion.create!(
          event: @event,
          name: "Opening discount",
          type: "percentage",
          percentage_basis_points: 1_000,
          currency: "ETB",
          status: "active",
          per_user_limit: 1
        )
        @code = Catalog::PromotionCode.new(promotion: @promotion, code: "SAVE10")
        @code.code_digest = Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "SAVE10")
        @code.save!
      end

      test "reveals the canonical code and audits without plaintext" do
        result = RevealCode.call(
          promotion_code: @code,
          actor: @actor,
          idempotency_key: "promotion-reveal-1"
        )

        assert result.success?, result.error&.message
        assert_equal "SAVE10", result.value
        audit = Core::AuditLog.where(action: "catalog.promotion.code_revealed").sole
        assert_not_includes audit.metadata.to_s, "SAVE10"
      end

      test "replay creates no duplicate reveal audit" do
        subject = lambda do
          RevealCode.call(
            promotion_code: @code,
            actor: @actor,
            idempotency_key: "promotion-reveal-2"
          )
        end

        assert_audit_idempotent(
          subject,
          action: "catalog.promotion.code_revealed",
          auditable_type: "Catalog::PromotionCode",
          auditable_id: @code.id
        )
      end
    end
  end
end
