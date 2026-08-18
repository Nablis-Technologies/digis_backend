# frozen_string_literal: true

module Commercial
  module Versions
    # Activates one scheduled version and supersedes the prior active version
    # while holding the schedule lock. Both status changes and their evidence
    # are committed together so resolution never sees a half-transition.
    class Activate < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(version:, actor:, idempotency_key:, break_glass: false, reason: nil)
        @version = version
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
          locked_version = FeeScheduleVersion.includes(:fee_schedule, :legal_document_version).lock.find(version.id)
          replay_or_conflict(locked_version) || activate_locked(locked_version)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :version, :actor, :idempotency_key, :key_digest, :fingerprint, :break_glass, :reason

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("version-activate", idempotency_key)
      end

      def replay_or_conflict(locked_version)
        @fingerprint = fingerprint_for(
          action: "activate", version_id: locked_version.id, actor_id: actor.id,
          break_glass:, reason_digest: fingerprint_for(reason)
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_version) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def activate_locked(locked_version)
        return failure(state_error) unless locked_version.status == "scheduled"
        return failure(governance_error("effective_time_invalid", code: "effective_time_invalid")) if locked_version.effective_from.blank? || locked_version.effective_from > Time.current
        return failure(governance_error("approval_required", code: "approval_required")) unless current_approval?(locked_version)
        return failure(governance_error("simulation_required", code: "simulation_required")) unless passing_simulation?(locked_version)
        policy_error = acceptance_policy_error(locked_version)
        return failure(policy_error) if policy_error

        previous = active_versions(locked_version).to_a
        previous.each { |active| active.update!(status: "superseded") }
        locked_version.update!(status: "active", activated_by: actor, activated_at: Time.current)
        record_transition!(
          target: locked_version, actor:, audit_key:, action: "commercial.version.activated",
          audited_changes: { "status" => [ "scheduled", "active" ], "superseded_version_ids" => previous.map(&:id) },
          metadata: { "request_fingerprint" => fingerprint },
          topic: "commercial", event_type: "commercial.version.activated",
          payload: { fee_schedule_version_id: locked_version.id, superseded_version_ids: previous.map(&:id), status: locked_version.status }
        )
        record_break_glass!(locked_version) if break_glass
        success(locked_version)
      end

      def active_versions(locked_version)
        FeeScheduleVersion.where(fee_schedule_id: locked_version.fee_schedule_id, status: "active")
          .where.not(id: locked_version.id).order(:id).lock
      end

      def current_approval?(locked_version)
        Approval.exists?(target_type: locked_version.class.name, target_id: locked_version.id,
                         decision: "approved", definition_digest: locked_version.definition_digest)
      end

      def passing_simulation?(locked_version)
        Simulation.where(fee_schedule_version_id: locked_version.id, assignment_id: nil,
                         definition_digest: locked_version.definition_digest, passed: true).exists?
      end

      def acceptance_policy_error(locked_version)
        classification = Simulation.where(fee_schedule_version_id: locked_version.id, assignment_id: nil,
                                          definition_digest: locked_version.definition_digest, passed: true)
          .order(run_at: :desc).pick(Arel.sql("normalized_outputs ->> 'classification'"))
        return governance_error("none_worsening_forbidden", code: "none_worsening_forbidden") if classification == "worsening" && locked_version.acceptance_policy == "none"
        return if locked_version.acceptance_policy == "none"
        return governance_error("legal_version_required", code: "legal_version_required") if locked_version.legal_document_version.blank?
        governance_error("legal_version_not_published", code: "legal_version_not_published") unless locked_version.legal_document_version.published?
      end

      def record_break_glass!(locked_version)
        security_key = "commercial-version-break-glass-#{key_digest}"
        record_transition!(
          target: locked_version, actor:, audit_key: security_key, action: "commercial.security.break_glass",
          audited_changes: { "operation" => "version_activate" },
          metadata: { "request_fingerprint" => fingerprint, "reason_digest" => fingerprint_for(reason) },
          topic: "security", event_type: "commercial.security.break_glass",
          payload: { fee_schedule_version_id: locked_version.id, operation: "version_activate" }, outbox_key: security_key
        )
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-version-activate-#{key_digest}"
      end
    end
  end
end
