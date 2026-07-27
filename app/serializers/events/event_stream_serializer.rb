# frozen_string_literal: true

module Events
  class EventStreamSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_stream

    attributes :id, :event_date_id, :provider, :access_protection, :status,
               :live_from, :live_until, :replay_enabled, :replay_available_until,
               :max_concurrent_devices, :created_at, :updated_at
  end
end
