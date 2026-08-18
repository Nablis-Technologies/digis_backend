# frozen_string_literal: true

module Commercial
  class FeeTierSerializer < ActiveModel::Serializer
    attributes :id, :fee_component_id, :position, :metric_type, :window_type,
      :currency, :starts_at_value, :rate_bps, :fixed_amount_minor,
      :minimum_minor, :maximum_minor, :created_at, :updated_at
  end
end
