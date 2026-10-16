# frozen_string_literal: true

module Events
  module Public
    class EventParticipantSerializer < ActiveModel::Serializer
      attributes :id, :artist_id, :event_date_id, :name, :type, :description, :display_order
    end
  end
end
