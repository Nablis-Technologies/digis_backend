# frozen_string_literal: true

module Catalog
  # Serializes one date allocation with its event date.
  class ProductDateAllocationSerializer < ActiveModel::Serializer
    attributes :id, :event_product_id, :event_date_id,
               :allocation_basis_points, :created_at, :updated_at

    belongs_to :event_date, serializer: Events::EventDateSerializer
  end
end
