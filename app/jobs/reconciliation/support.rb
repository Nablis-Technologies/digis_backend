# frozen_string_literal: true

module Reconciliation
  # Shared operational mechanics for reconciliation jobs. Domain jobs still
  # choose their own candidate scope and command; this module only standardizes
  # bounded rescheduling, telemetry, and idempotent transition evidence.
  module Support
    RESCHEDULE_DELAY = 1.minute

    private

    def bounded_limit(value, default)
      value.to_i.clamp(1, default)
    end

    def schedule_remaining(scope, limit)
      return unless scope.exists?

      self.class.set(wait: RESCHEDULE_DELAY).perform_later(limit)
    end

    def instrument_outcome(event_name, record:, batch_id:, outcome:, code: nil)
      Core::Telemetry.instrument(
        event_name,
        aggregate_type: record.class.name,
        aggregate_id: record.id,
        outcome:,
        code:,
        batch_id:
      ) { yield }
    end

    def require_success!(result)
      return result if result.success?

      raise result.error
    end

    def audit_status_transition(record, before:, after:, action:, batch_id:)
      return if before == after

      result = Core::Audit::Record.call(
        audit_key: "reconciliation:#{record.class.name}:#{record.id}:#{after}",
        action:,
        auditable_type: record.class.name,
        auditable_id: record.id,
        audited_changes: { status: [ before, after ] },
        metadata: { batch_id:, reconciliation: true }
      )
      raise result.error if result.failure?
    end
  end
end
