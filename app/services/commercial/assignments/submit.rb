# frozen_string_literal: true

module Commercial
  module Assignments
    # Submits a draft assignment only after a passing simulation bound to the
    # exact assigned version and assignment target has been recorded.
    class Submit < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(assignment:, actor:, idempotency_key:)
        @assignment = assignment
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        return failure(unauthorized_error("commercial.submit")) unless actor&.has_permission?("commercial.submit")

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_assignment = Commercial::Assignment.includes(fee_schedule_version: :fee_schedule).lock.find(assignment.id)
          replay_or_conflict(locked_assignment) || submit_locked(locked_assignment)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :assignment, :actor, :idempotency_key, :key_digest, :fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("assignment-submit", idempotency_key)
      end

      def replay_or_conflict(locked_assignment)
        @fingerprint = fingerprint_for(
          action: "submit", assignment_id: locked_assignment.id, actor_id: actor.id,
          definition_digest: locked_assignment.fee_schedule_version.definition_digest
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_assignment) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def submit_locked(locked_assignment)
        return failure(state_error) unless locked_assignment.status.in?(%w[draft pending_acceptance])
        return failure(unauthorized_error("commercial.grant")) if locked_assignment.platform_grant? && !actor.has_permission?("commercial.grant")
        return failure(governance_error("mutual_evidence_required", code: "mutual_evidence_required")) if locked_assignment.mutual_agreement? && !evidence_present?(locked_assignment)

        validation = Definitions::Validate.call(version: locked_assignment.fee_schedule_version)
        return failure(governance_error("definition_invalid", code: "definition_invalid")) if validation.failure?
        simulation = passing_simulation(locked_assignment, validation.value.digest)
        return failure(governance_error("simulation_required", code: "simulation_required")) unless simulation

        before = locked_assignment.status
        locked_assignment.update!(status: "pending_approval")
        record_transition!(
          target: locked_assignment, actor:, audit_key:, action: "commercial.assignment.submitted",
          audited_changes: { "status" => [ before, "pending_approval" ], "definition_digest" => validation.value.digest },
          metadata: { "request_fingerprint" => fingerprint, "simulation_id" => simulation.id },
          topic: "commercial", event_type: "commercial.assignment.submitted",
          payload: { assignment_id: locked_assignment.id, fee_schedule_version_id: locked_assignment.fee_schedule_version_id, status: locked_assignment.status }
        )
        success(locked_assignment)
      end

      def evidence_present?(locked_assignment)
        locked_assignment.legal_acceptance_id.present? || locked_assignment.external_reference.present?
      end

      def passing_simulation(locked_assignment, digest)
        Simulation.where(assignment_id: locked_assignment.id, fee_schedule_version_id: locked_assignment.fee_schedule_version_id,
                         definition_digest: digest, passed: true).order(run_at: :desc).first
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-assignment-submit-#{key_digest}"
      end
    end
  end
end
