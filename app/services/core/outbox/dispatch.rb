# frozen_string_literal: true

module Core
  module Outbox
    # Delivers one outbox event exactly-once-per-success by marking it published
    # only after the registered handler returns without error.
    #
    # Concurrency model:
    #   - A short in-transaction row lock claims the event so two dispatchers
    #     cannot run the same handler twice.
    #   - The external handler runs OUTSIDE that lock, so a slow/blocking
    #     handler never holds a database lock.
    #   - On success the row is flipped to published atomically.
    #   - On failure the claim is released, attempts is bumped, and the job
    #     retry (see Core::DispatchOutboxEventJob) replays it.
    class Dispatch < Core::BaseService
      class MissingHandler < Core::Error; end

      # How long a held claim is trusted before another dispatcher may reuse it.
      # Guards against a crashed worker leaving a row permanently locked.
      CLAIM_TIMEOUT = 5.minutes

      def initialize(event_id:)
        @event_id = event_id
      end

      def call
        event = claim!
        return success(nil) unless event
        return success(event) if event.published_at?

        @claimed = true
        handler_for(event).call(event)
        mark_published!(event)
        success(event.reload)
      rescue StandardError => error
        record_failure!(error) if @claimed
        raise
      end

      private

      # Lock the row for the duration of this short transaction only. Releasing
      # `locked_at` on success/failure (below) is what lets the next claimer in.
      def claim!
        Core::OutboxEvent.transaction do
          event = Core::OutboxEvent.lock.find(@event_id)
          return event if event.published_at?

          # A non-stale claim means another worker is mid-flight; skip this round.
          return if event.locked_at && event.locked_at > CLAIM_TIMEOUT.ago

          event.update!(locked_at: Time.current)
          event
        end
      end

      # Handlers are registered per event_type via
      # Rails.application.config.x.outbox_handlers. Each handler is responsible
      # for its own idempotency using the event's idempotency_key.
      def handler_for(event)
        Rails.application.config.x.outbox_handlers.fetch(event.event_type) do
          raise MissingHandler, I18n.t("core.errors.outbox_handler_missing", event_type: event.event_type)
        end
      end

      # Conditional update: only flips rows still unpublished, so a duplicate
      # delivery attempt cannot clobber an already-published event.
      def mark_published!(event)
        Core::OutboxEvent.where(id: event.id, published_at: nil)
          .update_all(published_at: Time.current, locked_at: nil, updated_at: Time.current)
      end

      # On handler failure, release the claim and record the error. The job's
      # retry policy replays the event; attempts caps runaway retries upstream.
      def record_failure!(error)
        Core::OutboxEvent.where(id: @event_id).update_all(
          attempts: Arel.sql("attempts + 1"),
          last_error_code: error.class.name.to_s.first(120),
          locked_at: nil,
          updated_at: Time.current
        )
      end
    end
  end
end
