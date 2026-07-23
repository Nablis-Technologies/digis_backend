# frozen_string_literal: true

module Events
  class EventDateSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_date

    attributes :id, :event_id, :venue_id, :name, :doors_at, :starts_at, :ends_at,
               :status, :venue_capacity, :held_venue_count, :issued_venue_count,
               :source_key, :created_at, :updated_at
  end
end
