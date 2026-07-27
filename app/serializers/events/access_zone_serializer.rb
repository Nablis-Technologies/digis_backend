# frozen_string_literal: true

module Events
  class AccessZoneSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :access_zone

    attributes :id, :event_id, :event_date_id, :type, :name, :code, :active,
               :sort_order, :created_at, :updated_at
  end
end
