# frozen_string_literal: true

module Commercial
  module Versions
    # Terminates a scheduled or active version without rewriting its immutable
    # definition or any historical quote evidence.
    class Terminate < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(version:, actor:, reason:, idempotency_key:)
        @version = version
        @actor = actor
        @reason = reason.to_s.strip
        @idempotency_key = idempotency_key
      end

      def call
        return failure(unauthorized_error("commercial.terminate")) unless actor&.has_permission?("commercial.terminate")
        return failure(governance_error("missing_reason", code: "missing_reason")) if reason.blank?

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_version = FeeScheduleVersion.lock.find(version.id)
          replay_or_conflict(locked_version) || terminate_locked(locked_version)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :version, :actor, :reason, :idempotency_key, :key_digest, :fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("version-terminate", idempotency_key)
      end

      def replay_or_conflict(locked_version)
        @fingerprint = fingerprint_for(
          action: "terminate", version_id: locked_version.id, actor_id: actor.id,
          reason_digest: fingerprint_for(reason)
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_version) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def terminate_locked(locked_version)
        return failure(state_error) unless locked_version.status.in?(%w[approved scheduled active])

        before = locked_version.status
        locked_version.update!(status: "terminated", terminated_by: actor, terminated_at: Time.current)
        record_transition!(
          target: locked_version, actor:, audit_key:, action: "commercial.version.terminated",
          audited_changes: { "status" => [ before, "terminated" ] },
          metadata: { "request_fingerprint" => fingerprint, "reason_digest" => fingerprint_for(reason) },
          topic: "commercial", event_type: "commercial.version.terminated",
          payload: { fee_schedule_version_id: locked_version.id, status: locked_version.status }
        )
        success(locked_version)
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-version-terminate-#{key_digest}"
      end
    end
  end
end
