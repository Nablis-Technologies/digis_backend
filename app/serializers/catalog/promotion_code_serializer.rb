# frozen_string_literal: true

module Catalog
  # Safe promotion-code metadata. Plaintext, digest, and ciphertext are never
  # serialized; plaintext is returned only by explicit create/reveal actions.
  class PromotionCodeSerializer < ActiveModel::Serializer
    attributes :id, :promotion_id, :label, :redemption_limit,
               :starts_at, :ends_at, :active, :created_at, :updated_at
  end
end
