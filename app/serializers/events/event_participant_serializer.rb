# frozen_string_literal: true

module Events
  class EventParticipantSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_participant

    attributes :id, :event_id, :event_date_id, :artist_id, :name, :type,
               :description, :display_order, :metadata, :created_at, :updated_at
  end
end
