# frozen_string_literal: true

module Events
  class EventDateSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_date

    attributes :id, :event_id, :venue_id, :name, :doors_at, :starts_at, :ends_at,
               :status, :venue_capacity, :held_venue_count, :issued_venue_count,
               :venue, :capacity,
               :source_key, :created_at, :updated_at

    attribute :venue do
      next unless object.venue

      Events::Public::VenueSummarySerializer.new(object.venue).attributes
    end

    attribute :capacity do
      limit = object.venue_capacity || object.venue&.capacity
      held = object.held_venue_count
      issued = object.issued_venue_count
      {
        limit:,
        held:,
        issued:,
        available: limit && limit - held - issued
      }
    end
  end
end
