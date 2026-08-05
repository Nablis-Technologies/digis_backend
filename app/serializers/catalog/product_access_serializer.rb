# frozen_string_literal: true

module Catalog
  # Serializes a product access row with its event date and zone grants.
  # Field visibility is intersected with the policy layer at render time.
  class ProductAccessSerializer < ActiveModel::Serializer
    attributes :id, :event_product_id, :event_date_id, :type,
               :required_access_protection, :usage_limit,
               :opens_offset_seconds, :closes_offset_seconds,
               :created_at, :updated_at

    belongs_to :event_date, serializer: Events::EventDateSerializer
    has_many :product_access_zones, serializer: Catalog::ProductAccessZoneSerializer
  end
end
