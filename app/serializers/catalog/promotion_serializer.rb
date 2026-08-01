# frozen_string_literal: true

module Catalog
  # Safe organizer-facing promotion definition and product scope.
  class PromotionSerializer < ActiveModel::Serializer
    attributes :id, :event_id, :supersedes_promotion_id, :version, :name, :type,
               :percentage_basis_points, :fixed_amount_minor, :currency,
               :minimum_subtotal_minor, :maximum_discount_minor,
               :redemption_limit, :per_user_limit, :starts_at, :ends_at,
               :status, :lock_version, :product_ids, :created_at, :updated_at

    has_many :promotion_codes, serializer: Catalog::PromotionCodeSerializer

    def product_ids
      object.promotion_products.map(&:event_product_id)
    end
  end
end
