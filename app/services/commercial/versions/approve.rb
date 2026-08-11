# frozen_string_literal: true

module Commercial
  module Versions
    # Records an immutable approval and promotes a pending version to approved.
    # Platform defaults always require a distinct checker; break-glass records
    # an additional security event and never waives acceptance requirements.
    class Approve < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(version:, actor:, reason:, idempotency_key:, break_glass: false)
        @version = version
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
          locked_version = FeeScheduleVersion.includes(:fee_schedule).lock.find(version.id)
          replay_or_conflict(locked_version) || approve_locked(locked_version)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :version, :actor, :reason, :idempotency_key, :key_digest, :fingerprint, :break_glass

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("version-approve", idempotency_key)
      end

      def replay_or_conflict(locked_version)
        @fingerprint = fingerprint_for(
          action: "approve", version_id: locked_version.id, actor_id: actor.id,
          reason_digest: fingerprint_for(reason), break_glass:
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_version) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def approve_locked(locked_version)
        return failure(state_error) unless locked_version.status == "pending_approval"

        validation = Definitions::Validate.call(version: locked_version)
        return failure(governance_error("definition_invalid", code: "definition_invalid")) if validation.failure?
        return failure(governance_error("simulation_required", code: "simulation_required")) unless passing_simulation?(locked_version, validation.value.digest)
        return failure(governance_error("maker_checker_required", code: "maker_checker_required")) if checker_required?(locked_version)

        approval = Approval.create!(
          target: locked_version, decision: "approved", reason:, definition_digest: validation.value.digest,
          actor:, decided_at: Time.current, idempotency_key_digest: key_digest,
          request_fingerprint: fingerprint
        )
        locked_version.update!(status: "approved", approved_by: actor, approved_at: Time.current)
        record_transition!(
          target: locked_version, actor:, audit_key:, action: "commercial.version.approved",
          audited_changes: { "status" => [ "pending_approval", "approved" ], "definition_digest" => validation.value.digest },
          metadata: { "request_fingerprint" => fingerprint, "approval_id" => approval.id },
          topic: "commercial", event_type: "commercial.version.approved",
          payload: { fee_schedule_version_id: locked_version.id, definition_digest: validation.value.digest, status: locked_version.status }
        )
        record_break_glass!(locked_version) if break_glass
        success(locked_version)
      end

      def passing_simulation?(locked_version, digest)
        Simulation.where(fee_schedule_version_id: locked_version.id, assignment_id: nil,
                         definition_digest: digest, passed: true).exists?
      end

      def checker_required?(locked_version)
        required = break_glass || locked_version.fee_schedule.schedule_type == "platform_default"
        required && locked_version.submitted_by_id == actor.id
      end

      def record_break_glass!(locked_version)
        security_key = "commercial-version-break-glass-#{key_digest}"
        record_transition!(
          target: locked_version, actor:, audit_key: security_key, action: "commercial.security.break_glass",
          audited_changes: { "operation" => "version_approve" },
          metadata: { "request_fingerprint" => fingerprint, "reason_digest" => fingerprint_for(reason) },
          topic: "security", event_type: "commercial.security.break_glass",
          payload: { fee_schedule_version_id: locked_version.id, operation: "version_approve" },
          outbox_key: security_key
        )
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-version-approve-#{key_digest}"
      end
    end
  end
end
