# frozen_string_literal: true

module Messaging
  # Serializes only the recipient-safe notification projection and sanitized
  # channel state; dedupe, provider, and outbox identities stay private.
  class NotificationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :notification_type, :category, :data, :read_at, :available_at, :created_at

    has_many :deliveries, serializer: Messaging::NotificationDeliverySerializer
  end
end
