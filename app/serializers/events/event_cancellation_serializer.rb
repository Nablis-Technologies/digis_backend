# frozen_string_literal: true

module Events
  class EventCancellationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_cancellation

    attributes :id, :event_id, :initiated_by_id, :attendee_reason,
               :status, :cancelled_at, :created_at, :updated_at
  end
end
