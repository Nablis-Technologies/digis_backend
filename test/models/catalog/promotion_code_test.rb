# frozen_string_literal: true

require "test_helper"

module Catalog
  class PromotionCodeTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
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

    test "normalizes codes by trimming and uppercasing" do
      assert_equal "SAVE10", Catalog::PromotionCode.normalize_code("  save10 ")
    end

    test "event-scoped digest changes with the event namespace" do
      other_event = events_events(:draft_concert)

      first = Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "save10")
      second = Catalog::PromotionCode.code_digest_for(event_id: other_event.id, code: "SAVE10")

      refute_equal first, second
      assert_equal first, Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: " SAVE10 ")
    end

    test "encrypts the canonical code value" do
      code = Catalog::PromotionCode.new(
        promotion: @promotion,
        code: " save10 ",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "save10")
      )
      code.save!

      assert_equal "SAVE10", code.code
      stored = Catalog::PromotionCode.connection.select_value(
        "SELECT code_ciphertext FROM catalog_promotion_codes WHERE id = '#{code.id}'"
      )
      refute_equal "SAVE10", stored
      refute_includes stored, "SAVE10"
    end

    test "requires code end after start" do
      code = Catalog::PromotionCode.new(
        promotion: @promotion,
        code: "SAVE10",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "SAVE10"),
        starts_at: 2.days.from_now,
        ends_at: 1.day.from_now
      )

      assert_not code.valid?
      assert_includes code.errors[:ends_at], I18n.t("catalog.promotion_code.errors.invalid_window")
    end

    test "exposes no secret fields through ransack" do
      attributes = Catalog::PromotionCode.ransackable_attributes

      assert_not_includes attributes, "code"
      assert_not_includes attributes, "code_ciphertext"
      assert_not_includes attributes, "code_digest"
    end
  end
end
