# frozen_string_literal: true

require "test_helper"

module Orders
  class PromotionContextTest < ActiveSupport::TestCase
    test "resolves a normalized code only within the promotion event" do
      event = events_events(:draft_concert)
      promotion = Catalog::Promotion.create!(
        event:,
        name: "Admission discount",
        type: "percentage",
        percentage_basis_points: 1_000,
        currency: "ETB",
        status: "active"
      )
      code = Catalog::PromotionCode.create!(
        promotion:,
        code: "SAVE10",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: event.id, code: "SAVE10")
      )

      result = PromotionContext.call(event:, raw_code: " save10 ")

      assert_predicate result, :success?
      assert_equal promotion.id, result.value.promotion.id
      assert_equal code.id, result.value.promotion_code.id
    end

    test "rejects a code that does not belong to the selected event" do
      event = events_events(:draft_concert)
      other_event = events_events(:ready_listing)
      promotion = Catalog::Promotion.create!(
        event: other_event,
        name: "Other event discount",
        type: "percentage",
        percentage_basis_points: 1_000,
        currency: "ETB",
        status: "active"
      )
      Catalog::PromotionCode.create!(
        promotion:,
        code: "OTHER10",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: other_event.id, code: "OTHER10")
      )

      result = PromotionContext.call(event:, raw_code: "OTHER10")

      assert_predicate result, :failure?
      assert_equal "invalid_promotion_code", result.error.code
    end
  end
end
