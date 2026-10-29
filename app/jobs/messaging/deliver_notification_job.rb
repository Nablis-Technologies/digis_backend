# frozen_string_literal: true

module Messaging
  # Delivers one persisted channel row. Only the row ID crosses the queue
  # boundary; notification content and provider credentials stay server-side.
  class DeliverNotificationJob < ApplicationJob
    queue_as :notifications
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(delivery_id)
      result = Messaging::DeliverNotification.call(delivery: delivery_id)
      raise result.error if result.failure?
    end
  end
end
