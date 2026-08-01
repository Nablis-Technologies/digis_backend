# frozen_string_literal: true

module Catalog
  # Serializes immutable promotion quote evidence for checkout consumers.
  class PromotionQuoteSerializer < ActiveModel::Serializer
    attributes :promotion_id, :promotion_code_id, :promotion_version,
               :eligible_product_ids, :eligible_subtotal_minor, :discount_minor,
               :charge_currency, :promotion_currency, :calculation_type,
               :percentage_basis_points, :fixed_amount_minor,
               :minimum_subtotal_minor, :maximum_discount_minor,
               :redemption_limit, :per_user_limit, :code_redemption_limit,
               :code_starts_at, :code_ends_at, :code_active,
               :exchange_rate_id, :exchange_rate_value, :at

    def read_attribute_for_serialization(attribute)
      object.public_send(attribute)
    end
  end
end
