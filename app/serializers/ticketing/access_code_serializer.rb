# frozen_string_literal: true

module Ticketing
  # Safe access-code metadata. The digest and submitted plaintext are never
  # serialized; plaintext is returned only from an explicit create response.
  class AccessCodeSerializer < ActiveModel::Serializer
    attributes :id, :ticket_type_id, :label, :max_uses, :used_count,
               :max_quantity_per_use, :starts_at, :expires_at, :active,
               :created_at, :updated_at
  end
end
