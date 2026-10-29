# frozen_string_literal: true

module Messaging
  # Serializes the small user-owned preference contract; no provider or billing
  # configuration is part of the notification foundation.
  class NotificationPreferenceSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :category, :channel, :enabled, :created_at, :updated_at
  end
end
