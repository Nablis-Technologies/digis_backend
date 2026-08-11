# frozen_string_literal: true

module Commercial
  module Assignments
    # Approves a pending assignment and schedules it for its immutable
    # effective time. Risk rules distinguish bounded beneficial grants from
    # mutual, default, and high-exposure changes that need a checker.
    class Approve < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(assignment:, actor:, reason:, idempotency_key:, break_glass: false)
        @assignment = assignment
        @actor = actor
        @reason = reason.to_s.strip
        @idempotency_key = idempotency_key
        @break_glass = break_glass
      end

      def call
        return failure(unauthorized_error("commercial.approve")) unless actor&.has_permission?("commercial.approve")
        return failure(governance_error("break_glass_reason_required", code: "break_glass_reason_required")) if break_glass && reason.blank?
        return failure(governance_error("missing_reason", code: "missing_reason")) if reason.blank?
        return failure(unauthorized_error("commercial.break_glass")) if break_glass && !actor.has_permission?("commercial.break_glass")

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_assignment = Commercial::Assignment.includes(
            fee_schedule_version: %i[fee_schedule legal_document_version]
          ).lock.find(assignment.id)
          replay_or_conflict(locked_assignment) || approve_locked(locked_assignment)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :assignment, :actor, :reason, :idempotency_key, :key_digest, :fingerprint, :break_glass

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("assignment-approve", idempotency_key)
      end

      def replay_or_conflict(locked_assignment)
        @fingerprint = fingerprint_for(
          action: "approve", assignment_id: locked_assignment.id, actor_id: actor.id,
          reason_digest: fingerprint_for(reason), break_glass:
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_assignment) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def approve_locked(locked_assignment)
        return failure(state_error) unless locked_assignment.status == "pending_approval"
        return failure(unauthorized_error("commercial.grant")) if locked_assignment.platform_grant? && !actor.has_permission?("commercial.grant")
        return failure(acceptance_error) if locked_assignment.mutual_agreement? && !evidence_present?(locked_assignment)

        validation = Definitions::Validate.call(version: locked_assignment.fee_schedule_version)
        return failure(governance_error("definition_invalid", code: "definition_invalid")) if validation.failure?
        simulation = passing_simulation(locked_assignment, validation.value.digest)
        return failure(governance_error("simulation_required", code: "simulation_required")) unless simulation
        return failure(governance_error("approval_required", code: "approval_required")) unless beneficial_grant?(locked_assignment, simulation)
        return failure(governance_error("maker_checker_required", code: "maker_checker_required")) if checker_required?(locked_assignment, simulation)

        approval = Approval.create!(
          target: locked_assignment, decision: "approved", reason:, definition_digest: validation.value.digest,
          actor:, decided_at: Time.current, idempotency_key_digest: key_digest,
          request_fingerprint: fingerprint
        )
        locked_assignment.update!(status: "scheduled", approved_by: actor, approved_at: Time.current)
        record_transition!(
          target: locked_assignment, actor:, audit_key:, action: "commercial.assignment.approved",
          audited_changes: { "status" => [ "pending_approval", "scheduled" ], "definition_digest" => validation.value.digest },
          metadata: { "request_fingerprint" => fingerprint, "approval_id" => approval.id },
          topic: "commercial", event_type: "commercial.assignment.approved",
          payload: { assignment_id: locked_assignment.id, fee_schedule_version_id: locked_assignment.fee_schedule_version_id, status: locked_assignment.status }
        )
        record_break_glass!(locked_assignment) if break_glass
        success(locked_assignment)
      end

      def passing_simulation(locked_assignment, digest)
        Simulation.where(assignment_id: locked_assignment.id, fee_schedule_version_id: locked_assignment.fee_schedule_version_id,
                         definition_digest: digest, passed: true).order(run_at: :desc).first
      end

      def beneficial_grant?(locked_assignment, simulation)
        return true unless locked_assignment.platform_grant?

        simulation.normalized_outputs["classification"] == "beneficial"
      end

      def checker_required?(locked_assignment, simulation)
        return false unless locked_assignment.created_by_id == actor.id
        return false if bounded_beneficial_grant?(locked_assignment, simulation)

        true
      end

      def bounded_beneficial_grant?(locked_assignment, simulation)
        locked_assignment.platform_grant? && locked_assignment.effective_until.present? &&
          beneficial_grant?(locked_assignment, simulation)
      end

      def evidence_present?(locked_assignment)
        locked_assignment.legal_acceptance_id.present? || locked_assignment.external_reference.present?
      end

      def acceptance_error
        return governance_error("break_glass_acceptance_forbidden", code: "break_glass_acceptance_forbidden") if break_glass

        governance_error("mutual_evidence_required", code: "mutual_evidence_required")
      end

      def record_break_glass!(locked_assignment)
        security_key = "commercial-assignment-break-glass-#{key_digest}"
        record_transition!(
          target: locked_assignment, actor:, audit_key: security_key, action: "commercial.security.break_glass",
          audited_changes: { "operation" => "assignment_approve" },
          metadata: { "request_fingerprint" => fingerprint, "reason_digest" => fingerprint_for(reason) },
          topic: "security", event_type: "commercial.security.break_glass",
          payload: { assignment_id: locked_assignment.id, operation: "assignment_approve" }, outbox_key: security_key
        )
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-assignment-approve-#{key_digest}"
      end
    end
  end
end
