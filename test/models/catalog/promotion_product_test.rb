# frozen_string_literal: true

require "test_helper"

module Catalog
  class PromotionProductTest < ActiveSupport::TestCase
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

    test "requires a promotion product pair to be unique" do
      Catalog::PromotionProduct.create!(promotion: @promotion, event_product: @product)
      duplicate = Catalog::PromotionProduct.new(promotion: @promotion, event_product: @product)

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:event_product_id], "has already been taken"
    end

    test "rejects a product from another event" do
      scope = Catalog::PromotionProduct.new(promotion: @promotion, event_product: @other_product)

      assert_not scope.valid?
      assert_includes scope.errors[:event_product], I18n.t("catalog.promotion.errors.event_mismatch")
    end
  end
end
