# frozen_string_literal: true

module Marketplace
  # Seller-facing immutable balance fact. Idempotency keys and provider
  # diagnostics are intentionally absent even when the seller owns the row.
  class SellerLedgerEntrySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :seller_user_id, :event_id, :resale_sale_id, :type, :amount_minor,
               :currency, :available_at, :description, :created_at
  end
end
