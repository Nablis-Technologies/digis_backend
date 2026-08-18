# frozen_string_literal: true

module Commercial
  module Assignments
    # Records an append-only assignment rejection and returns the assignment to
    # draft state for correction; prior evidence remains immutable history.
    class Reject < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(assignment:, actor:, reason:, idempotency_key:)
        @assignment = assignment
        @actor = actor
        @reason = reason.to_s.strip
        @idempotency_key = idempotency_key
      end

      def call
        return failure(unauthorized_error("commercial.approve")) unless actor&.has_permission?("commercial.approve")
        return failure(governance_error("missing_reason", code: "missing_reason")) if reason.blank?

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_assignment = Commercial::Assignment.lock.find(assignment.id)
          replay_or_conflict(locked_assignment) || reject_locked(locked_assignment)
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
        @key_digest = idempotency_digest("assignment-reject", idempotency_key)
      end

      def replay_or_conflict(locked_assignment)
        @fingerprint = fingerprint_for(
          action: "reject", assignment_id: locked_assignment.id, actor_id: actor.id,
          reason_digest: fingerprint_for(reason)
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_assignment) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def reject_locked(locked_assignment)
        return failure(governance_error("state_conflict", code: "state_conflict")) unless locked_assignment.status == "pending_approval"

        approval = Approval.create!(
          target: locked_assignment, decision: "rejected", reason:,
          definition_digest: locked_assignment.fee_schedule_version.definition_digest,
          actor:, decided_at: Time.current, idempotency_key_digest: key_digest,
          request_fingerprint: fingerprint
        )
        locked_assignment.update!(status: "draft")
        record_transition!(
          target: locked_assignment, actor:, audit_key:, action: "commercial.assignment.rejected",
          audited_changes: { "status" => [ "pending_approval", "draft" ] },
          metadata: { "request_fingerprint" => fingerprint, "approval_id" => approval.id },
          topic: "commercial", event_type: "commercial.assignment.rejected",
          payload: { assignment_id: locked_assignment.id, status: locked_assignment.status }
        )
        success(locked_assignment)
      end

      def audit_key
        "commercial-assignment-reject-#{key_digest}"
      end
    end
  end
end
