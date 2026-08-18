# frozen_string_literal: true

module Ticketing
  # Safe playback-session projection. The Digis token digest and provider
  # playback grant are returned only through their explicit command responses.
  class StreamSessionSerializer < ActiveModel::Serializer
    attributes :id, :ticket_id, :event_stream_id, :user_id, :device_id, :status,
               :expires_at, :last_seen_at, :revoked_at, :created_at, :updated_at
  end
end
