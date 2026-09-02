# frozen_string_literal: true

module Events
  module Organizer
    # Organizer schedule projection. Capacity is event-date allocation state,
    # so it remains separate from the venue's reusable master record.
    class EventDateSerializer < ActiveModel::Serializer
      attributes :id, :name, :doors_at, :starts_at, :ends_at, :status, :venue, :capacity

      def venue
        return unless object.venue

        Events::Public::VenueSummarySerializer.new(object.venue).attributes
      end

      def capacity
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
end
