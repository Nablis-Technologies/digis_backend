# frozen_string_literal: true

module Commercial
  module Versions
    # Moves a simulated fee definition into approval. The simulation lookup is
    # digest-bound and happens while the version row is locked, so edits cannot
    # race a submission into using stale evidence.
    class Submit < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(version:, actor:, idempotency_key:)
        @version = version
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        return failure(unauthorized_error("commercial.submit")) unless actor&.has_permission?("commercial.submit")

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_version = FeeScheduleVersion.lock.find(version.id)
          replay_or_conflict(locked_version) || submit_locked(locked_version)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :version, :actor, :idempotency_key, :key_digest, :fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("version-submit", idempotency_key)
      end

      def replay_or_conflict(locked_version)
        @fingerprint = fingerprint_for(
          action: "submit", version_id: locked_version.id, actor_id: actor.id,
          definition_digest: locked_version.definition_digest
        )
        status = replay_status(
          audit_key: audit_key, actor:, fingerprint:
        )
        return success(locked_version) if status == :replay
        failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict
      end

      def submit_locked(locked_version)
        return failure(state_error) unless locked_version.status.in?(%w[draft simulated])

        validation = Definitions::Validate.call(version: locked_version)
        return failure(governance_error("definition_invalid", code: "definition_invalid")) if validation.failure?

        digest = validation.value.digest
        simulation = Simulation.where(
          fee_schedule_version_id: locked_version.id,
          assignment_id: nil,
          definition_digest: digest,
          passed: true
        ).order(run_at: :desc).first
        return failure(governance_error("simulation_required", code: "simulation_required")) unless simulation

        before = locked_version.status
        locked_version.update!(status: "pending_approval", submitted_by: actor, submitted_at: Time.current)
        record_transition!(
          target: locked_version, actor:, audit_key:, action: "commercial.version.submitted",
          audited_changes: { "status" => [ before, locked_version.status ], "definition_digest" => digest },
          metadata: { "request_fingerprint" => fingerprint, "simulation_id" => simulation.id },
          topic: "commercial", event_type: "commercial.version.submitted",
          payload: { fee_schedule_version_id: locked_version.id, definition_digest: digest, status: locked_version.status }
        )
        success(locked_version)
      end

      def state_error
        governance_error("state_conflict", code: "state_conflict")
      end

      def audit_key
        "commercial-version-submit-#{key_digest}"
      end
    end
  end
end
