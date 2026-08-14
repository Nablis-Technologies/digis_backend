# frozen_string_literal: true

module Events
  # Drains a bounded slice of one cancellation's payment snapshots. Each
  # service call claims with SKIP LOCKED, so concurrent workers can share a
  # cancellation without double-creating refund obligations. Pending-funds
  # work is rescheduled for its durable retry time rather than hot-looped.
  class ProcessCancellationBatchJob < ApplicationJob
    retry_on StandardError, wait: 30.seconds, attempts: 5

    def perform(cancellation_id)
      cancellation = Events::EventCancellation.find(cancellation_id)
      result = Events::Cancellation::ProcessPayment.call(cancellation:, now: Time.current)
      raise result.error if result.failure?

      schedule_next_batch(cancellation.id)
    end

    private

    def schedule_next_batch(cancellation_id)
      pending = Events::EventCancellationPayment.where(
        event_cancellation_id: cancellation_id, status: %w[pending processing]
      )
      return unless pending.exists?

      next_retry_at = pending.minimum(:next_retry_at)
      if next_retry_at.present?
        self.class.set(wait_until: next_retry_at).perform_later(cancellation_id)
      else
        self.class.perform_later(cancellation_id)
      end
    end
  end
end
