# frozen_string_literal: true

module Catalog
  # Serializes inventory pool state for organizers and admins. Capacity and
  # counter fields are gated by the policy layer — non-admin roles receive
  # only structural fields.
  class ProductInventorySerializer < ActiveModel::Serializer
    attributes :id, :event_product_id, :event_date_id, :capacity,
               :held_count, :sold_count, :lock_version,
               :created_at, :updated_at
  end
end
