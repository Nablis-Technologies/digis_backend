# frozen_string_literal: true

module Events
  module Public
    # Schedule projection with a deliberately small venue summary.
    class EventDateSerializer < ActiveModel::Serializer
      attributes :id, :name, :doors_at, :starts_at, :ends_at, :status, :venue, :series_id

      def series_id
        match = object.source_key.to_s.match(/\Arecurrence-([0-9a-f-]{36})-\d+\z/i)
        match&.captures&.first
      end

      def venue
        return unless object.venue

        Events::Public::VenueSummarySerializer.new(object.venue).attributes
      end
    end
  end
end
