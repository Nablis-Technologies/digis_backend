# frozen_string_literal: true

module Events
  module Public
    # Schedule projection with a deliberately small venue summary.
    class EventDateSerializer < ActiveModel::Serializer
      attributes :id, :name, :doors_at, :starts_at, :ends_at, :status, :venue

      def venue
        return unless object.venue

        Events::Public::VenueSummarySerializer.new(object.venue).attributes
      end
    end
  end
end
