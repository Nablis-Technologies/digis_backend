# frozen_string_literal: true

module Messaging
  # Schedules due channel deliveries in small, lock-skipping pages. The job
  # never performs provider I/O; each delivery job owns its claim and retry
  # state, so one enqueue failure cannot stop later rows from being scheduled.
  class ProcessNotificationsJob < ApplicationJob
    queue_as :notifications

    BATCH_SIZE = 100
    CLAIM_TIMEOUT = 5.minutes

    def perform(limit = BATCH_SIZE)
      claims = claimable_delivery_claims(limit)
      failures = claims.filter_map { |claim| enqueue_delivery(**claim) }
      Rails.logger.warn("Messaging notification scheduling failures: #{failures.tally.inspect}") if failures.any?
      claims.length
    end

    private

    def claimable_delivery_claims(limit)
      now = Time.current
      Messaging::NotificationDelivery.transaction do
        deliveries = claimable_deliveries(limit, now).to_a
        deliveries.each do |delivery|
          delivery.update_columns(enqueue_claimed_at: now, updated_at: now)
        end
        deliveries.map { |delivery| { delivery_id: delivery.id } }
      end
    end

    def claimable_deliveries(limit, now)
      Messaging::NotificationDelivery
        .joins(:notification)
        .where(status: %w[pending processing])
        .where("messaging_notifications.erased_at IS NULL")
        .where("messaging_notifications.available_at <= ?", now)
        .where("scheduled_at IS NULL OR scheduled_at <= ?", now)
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        .where("enqueue_claimed_at IS NULL OR enqueue_claimed_at <= ?", CLAIM_TIMEOUT.ago)
        .where("status = 'pending' OR claimed_at IS NULL OR claimed_at <= ?", CLAIM_TIMEOUT.ago)
        .order(:scheduled_at, :id)
        .limit(limit.to_i.clamp(1, BATCH_SIZE))
        .lock("FOR UPDATE SKIP LOCKED")
    end

    def enqueue_delivery(delivery_id:)
      DeliverNotificationJob.perform_later(delivery_id)
      nil
    rescue StandardError => error
      # An enqueue exception is ambiguous: Solid Queue may have persisted the
      # job before surfacing the failure. Keep the lease and let its bounded
      # expiry provide recovery without creating an immediate duplicate storm.
      error.class.name.to_s
    end
  end
end
