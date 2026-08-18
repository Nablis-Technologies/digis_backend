# frozen_string_literal: true

module Marketplace
  # Organizer-safe ticket-type resale policy projection.
  class ResalePolicySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_product_id, :resale_enabled, :resale_cutoff_seconds_before_start,
               :resale_price_cap_type, :resale_fixed_cap_minor, :resale_fixed_cap_currency,
               :resale_percentage_cap_bps, :max_completed_resales, :created_at, :updated_at
  end
end
