# frozen_string_literal: true

module Commercial
  module Assignments
    # Terminates an assignment while preserving the historical assignment and
    # its acceptance/simulation evidence.
    class Terminate < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(assignment:, actor:, reason:, idempotency_key:)
        @assignment = assignment
        @actor = actor
        @reason = reason.to_s.strip
        @idempotency_key = idempotency_key
      end

      def call
        return failure(unauthorized_error("commercial.terminate")) unless actor&.has_permission?("commercial.terminate")
        return failure(governance_error("missing_reason", code: "missing_reason")) if reason.blank?

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_assignment = Commercial::Assignment.lock.find(assignment.id)
          replay_or_conflict(locked_assignment) || terminate_locked(locked_assignment)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :assignment, :actor, :reason, :idempotency_key, :key_digest, :fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("assignment-terminate", idempotency_key)
      end

      def replay_or_conflict(locked_assignment)
        @fingerprint = fingerprint_for(
          action: "terminate", assignment_id: locked_assignment.id, actor_id: actor.id,
          reason_digest: fingerprint_for(reason)
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_assignment) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def terminate_locked(locked_assignment)
        return failure(state_error) unless locked_assignment.status.in?(%w[scheduled active])

        before = locked_assignment.status
        locked_assignment.update!(status: "terminated", terminated_by: actor, terminated_at: Time.current)
        record_transition!(
          target: locked_assignment, actor:, audit_key:, action: "commercial.assignment.terminated",
          audited_changes: { "status" => [ before, "terminated" ] },
          metadata: { "request_fingerprint" => fingerprint, "reason_digest" => fingerprint_for(reason) },
          topic: "commercial", event_type: "commercial.assignment.terminated",
          payload: { assignment_id: locked_assignment.id, status: locked_assignment.status }
        )
        success(locked_assignment)
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-assignment-terminate-#{key_digest}"
      end
    end
  end
end
