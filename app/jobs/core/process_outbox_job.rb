# frozen_string_literal: true

module Core
  # Periodic driver for the transactional outbox: claims due rows in batches and
  # enqueues their delivery. Doubles as the recovery sweep for rows whose job
  # retries were exhausted.
  #
  # Delivery is pull-based: this job is the only thing that turns an
  # `core_outbox_events` row into a `Core::DispatchOutboxEventJob`. Without it,
  # rows written by `Core::Outbox::Publish` sit at `published_at = NULL` forever.
  class ProcessOutboxJob < ApplicationJob
    queue_as :outbox
    BATCH_SIZE = 100
    MAX_ATTEMPTS = 10

    def perform
      claimed_ids = Core::OutboxEvent.transaction do
        Core::OutboxEvent
          .where(published_at: nil)
          .where("available_at <= ?", Time.current)
          .where("attempts < ?", MAX_ATTEMPTS)
          .order(:available_at)
          .limit(BATCH_SIZE)
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)
          .then do |ids|
            next ids if ids.empty?

            Core::OutboxEvent.where(id: ids)
              .update_all(available_at: Time.current + backoff, updated_at: Time.current)
            ids
          end
      end
      claimed_ids.each { |id| Core::DispatchOutboxEventJob.perform_later(id) }
    end

    private

    def backoff
      30.seconds
    end
  end
end
