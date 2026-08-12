# frozen_string_literal: true

module Commercial
  module Versions
    # Records an append-only rejection and returns a version to draft authoring
    # without mutating the submitted definition or deleting approval evidence.
    class Reject < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(version:, actor:, reason:, idempotency_key:)
        @version = version
        @actor = actor
        @reason = reason.to_s.strip
        @idempotency_key = idempotency_key
      end

      def call
        return failure(unauthorized_error("commercial.approve")) unless actor&.has_permission?("commercial.approve")
        return failure(governance_error("missing_reason", code: "missing_reason")) if reason.blank?

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_version = FeeScheduleVersion.lock.find(version.id)
          replay_or_conflict(locked_version) || reject_locked(locked_version)
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
        @key_digest = idempotency_digest("version-reject", idempotency_key)
      end

      def replay_or_conflict(locked_version)
        @fingerprint = fingerprint_for(
          action: "reject", version_id: locked_version.id, actor_id: actor.id,
          reason_digest: fingerprint_for(reason)
        )
        status = replay_status(audit_key:, actor:, fingerprint:)
        return success(locked_version) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def reject_locked(locked_version)
        return failure(governance_error("state_conflict", code: "state_conflict")) unless locked_version.status == "pending_approval"

        approval = Approval.create!(
          target: locked_version, decision: "rejected", reason:,
          definition_digest: locked_version.definition_digest, actor:,
          decided_at: Time.current, idempotency_key_digest: key_digest,
          request_fingerprint: fingerprint
        )
        locked_version.update!(status: "draft")
        record_transition!(
          target: locked_version, actor:, audit_key:, action: "commercial.version.rejected",
          audited_changes: { "status" => [ "pending_approval", "draft" ] },
          metadata: { "request_fingerprint" => fingerprint, "approval_id" => approval.id },
          topic: "commercial", event_type: "commercial.version.rejected",
          payload: { fee_schedule_version_id: locked_version.id, status: locked_version.status }
        )
        success(locked_version)
      end

      def audit_key
        "commercial-version-reject-#{key_digest}"
      end
    end
  end
end
