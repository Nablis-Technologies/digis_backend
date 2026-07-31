# frozen_string_literal: true

module Catalog
  # Serializes one zone grant with its access zone details.
  class ProductAccessZoneSerializer < ActiveModel::Serializer
    attributes :id, :product_access_id, :access_zone_id, :created_at, :updated_at

    belongs_to :access_zone, serializer: Events::AccessZoneSerializer
  end
end
