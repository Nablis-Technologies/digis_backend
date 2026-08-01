# frozen_string_literal: true

module Catalog
  # Optional product scope for a promotion. An empty scope means every product
  # in the promotion's event is eligible.
  class PromotionProduct < Catalog::ApplicationRecord
    self.table_name = "catalog_promotion_products"

    belongs_to :promotion, class_name: "Catalog::Promotion", inverse_of: :promotion_products
    belongs_to :event_product, class_name: "Catalog::EventProduct"

    validates :promotion, presence: true
    validates :event_product, presence: true
    validates :event_product_id, uniqueness: { scope: :promotion_id }
    validate :same_event

    def self.ransackable_attributes(_auth_object = nil)
      %w[id promotion_id event_product_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[promotion event_product]
    end

    private

    def same_event
      return if promotion.blank? || event_product.blank?
      return if promotion.event_id == event_product.event_id

      errors.add(:event_product, I18n.t("catalog.promotion.errors.event_mismatch"))
    end
  end
end
