# frozen_string_literal: true

module Reconciliation
  # Backstops outbox rows that are overdue or exhausted normal dispatch retries.
  # Core::ProcessOutboxJob remains the primary enqueuer; this job invokes the
  # existing dispatcher and never copies provider or event payloads into jobs.
  class OutboxJob < ApplicationJob
    include Reconciliation::Support

    queue_as :outbox
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    BATCH_SIZE = 100
    MAX_ATTEMPTS = 10
    OVERDUE_AFTER = 5.minutes

    def perform(limit = BATCH_SIZE, now: Time.current)
      batch_id = SecureRandom.uuid
      batch_limit = bounded_limit(limit, BATCH_SIZE)
      event_ids = claim_event_ids(batch_limit, now)
      event_ids.each { |event_id| reconcile_event(event_id, batch_id:) }
      schedule_remaining(candidate_scope(now), batch_limit)
    end

    private

    def candidate_scope(now)
      Core::OutboxEvent
        .where(published_at: nil)
        .where(
          "attempts >= :max_attempts OR (available_at <= :now AND available_at <= :overdue_at)",
          max_attempts: MAX_ATTEMPTS,
          now:,
          overdue_at: now - OVERDUE_AFTER
        )
    end

    def claim_event_ids(limit, now)
      Core::OutboxEvent.transaction do
        candidate_scope(now)
          .order(:available_at, :id)
          .limit(limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)
      end
    end

    def reconcile_event(event_id, batch_id:)
      event = Core::OutboxEvent.find(event_id)
      before = event.published_at
      result = Core::Outbox::Dispatch.call(event_id:)
      require_success!(result)
      event = event.reload
      audit_published_event(event, before:, batch_id:)
      instrument_outcome(
        "reconciliation.outbox",
        record: event,
        batch_id:,
        outcome: event.published_at? ? "published" : "pending"
      ) { event }
    rescue StandardError => error
      instrument_outcome(
        "reconciliation.outbox",
        record: event || Core::OutboxEvent.find(event_id),
        batch_id:,
        outcome: "error",
        code: error.class.name
      ) { raise }
    end

    def audit_published_event(event, before:, batch_id:)
      return if before.present? || event.published_at.blank?

      result = Core::Audit::Record.call(
        audit_key: "reconciliation:outbox:#{event.id}:published",
        action: "reconciliation.outbox.published",
        auditable_type: event.class.name,
        auditable_id: event.id,
        audited_changes: { published_at: [ nil, event.published_at.iso8601 ] },
        metadata: { attempts: event.attempts, batch_id: }
      )
      raise result.error if result.failure?
    end
  end
end
