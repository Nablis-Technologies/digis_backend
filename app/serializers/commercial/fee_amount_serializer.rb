# frozen_string_literal: true

module Commercial
  class FeeAmountSerializer < ActiveModel::Serializer
    attributes :id, :fee_component_id, :currency, :fixed_amount_minor,
      :minimum_minor, :maximum_minor, :created_at, :updated_at
  end
end
