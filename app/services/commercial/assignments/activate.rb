# frozen_string_literal: true

module Commercial
  module Assignments
    # Activates a scheduled assignment only after rechecking current
    # simulation, explicit mutual evidence, and effective-time constraints.
    class Activate < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(assignment:, actor:, idempotency_key:, break_glass: false, reason: nil)
        @assignment = assignment
        @actor = actor
        @idempotency_key = idempotency_key
        @break_glass = break_glass
        @reason = reason.to_s.strip
      end

      def call
        return failure(unauthorized_error("commercial.activate")) unless actor&.has_permission?("commercial.activate")
        return failure(unauthorized_error("commercial.break_glass")) if break_glass && !actor.has_permission?("commercial.break_glass")
        return failure(governance_error("break_glass_reason_required", code: "break_glass_reason_required")) if break_glass && reason.blank?

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_assignment = Commercial::Assignment.includes(
            :legal_acceptance, fee_schedule_version: %i[fee_schedule legal_document_version]
          ).lock.find(assignment.id)
          replay_or_conflict(locked_assignment) || activate_locked(locked_assignment)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :assignment, :actor, :idempotency_key, :key_digest, :fingerprint, :break_glass, :reason

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("assignment-activate", idempotency_key)
      end

      def replay_or_conflict(locked_assignment)
        @fingerprint = fingerprint_for(
          action: "activate", assignment_id: locked_assignment.id, actor_id: actor.id,
          reason_digest: fingerprint_for(reason), break_glass:
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_assignment) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def activate_locked(locked_assignment)
        return failure(state_error) unless locked_assignment.status == "scheduled"
        return failure(governance_error("effective_time_invalid", code: "effective_time_invalid")) if locked_assignment.effective_from > Time.current
        return failure(unauthorized_error("commercial.grant")) if locked_assignment.platform_grant? && !actor.has_permission?("commercial.grant")

        validation = Definitions::Validate.call(version: locked_assignment.fee_schedule_version)
        return failure(governance_error("definition_invalid", code: "definition_invalid")) if validation.failure?
        simulation = passing_simulation(locked_assignment, validation.value.digest)
        return failure(governance_error("simulation_required", code: "simulation_required")) unless simulation
        return failure(governance_error("approval_required", code: "approval_required")) unless current_approval?(locked_assignment, validation.value.digest)
        return failure(acceptance_error) if locked_assignment.mutual_agreement? && !evidence_present?(locked_assignment)
        return failure(governance_error("approval_required", code: "approval_required")) if locked_assignment.platform_grant? && simulation.normalized_outputs["classification"] != "beneficial"

        locked_assignment.update!(status: "active", activated_by: actor, activated_at: Time.current)
        record_transition!(
          target: locked_assignment, actor:, audit_key:, action: "commercial.assignment.activated",
          audited_changes: { "status" => [ "scheduled", "active" ], "definition_digest" => validation.value.digest },
          metadata: { "request_fingerprint" => fingerprint, "simulation_id" => simulation.id },
          topic: "commercial", event_type: "commercial.assignment.activated",
          payload: { assignment_id: locked_assignment.id, fee_schedule_version_id: locked_assignment.fee_schedule_version_id, status: locked_assignment.status }
        )
        record_break_glass!(locked_assignment) if break_glass
        success(locked_assignment)
      end

      def passing_simulation(locked_assignment, digest)
        Simulation.where(assignment_id: locked_assignment.id, fee_schedule_version_id: locked_assignment.fee_schedule_version_id,
                         definition_digest: digest, passed: true).order(run_at: :desc).first
      end

      def current_approval?(locked_assignment, digest)
        Approval.exists?(target_type: locked_assignment.class.name, target_id: locked_assignment.id,
                         decision: "approved", definition_digest: digest)
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
          audited_changes: { "operation" => "assignment_activate" },
          metadata: { "request_fingerprint" => fingerprint, "reason_digest" => fingerprint_for(reason) },
          topic: "security", event_type: "commercial.security.break_glass",
          payload: { assignment_id: locked_assignment.id, operation: "assignment_activate" }, outbox_key: security_key
        )
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-assignment-activate-#{key_digest}"
      end
    end
  end
end
