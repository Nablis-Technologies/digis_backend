# frozen_string_literal: true

module Commercial
  class EventPayerSelectionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_id, :fee_component_id, :charged_to, :selected_at,
      :selected_by_id, :created_at, :updated_at
  end
end
