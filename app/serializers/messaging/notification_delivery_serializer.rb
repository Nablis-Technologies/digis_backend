# frozen_string_literal: true

module Messaging
  # Exposes delivery lifecycle fields without provider message IDs, digests,
  # raw failure details, or credentials that could aid an external replay.
  class NotificationDeliverySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :channel, :status, :sent_at, :delivered_at, :failed_at, :failure_code
  end
end
