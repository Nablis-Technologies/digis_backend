# frozen_string_literal: true

module Messaging
  # Replays one ambiguous provider attempt with the delivery idempotency key.
  class RecoverCampaignDeliveryJob < ApplicationJob
    queue_as :notifications

    def perform(delivery_id)
      result = Campaigns::Deliver.call(delivery_id:)
      raise result.error if result.failure?

      delivery = result.value
      return unless delivery&.status == "pending" && delivery.next_attempt_at

      self.class.set(wait_until: delivery.next_attempt_at).perform_later(delivery.id)
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end
end
