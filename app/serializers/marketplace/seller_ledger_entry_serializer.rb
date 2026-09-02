# frozen_string_literal: true

module Marketplace
  # Seller-facing immutable balance fact. Idempotency keys and provider
  # diagnostics are intentionally absent even when the seller owns the row.
  class SellerLedgerEntrySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :seller_user_id, :event_id, :resale_sale_id, :type, :amount_minor,
               :currency, :available_at, :description, :event, :created_at

    attribute :event do
      event = object.event
      next unless event

      { id: event.id, slug: event.slug, title: event.title }
    end
  end
end
