# frozen_string_literal: true

module Events
  class EventOrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_organization

    attributes :id, :type, :role, :status, :organization_id, :event_id,
               :created_at, :updated_at
  end
end
