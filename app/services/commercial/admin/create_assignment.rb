# frozen_string_literal: true

module Commercial
  module Admin
    # Adds an idempotent API boundary around the existing assignment draft
    # command without changing its lower-level service contract. The wrapper
    # owns replay identity; CreateDraft continues to own assignment invariants.
    class CreateAssignment < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(organization:, actor:, fee_schedule_version:, assignment_type:, reason:,
                     effective_from:, event: nil, program: nil, effective_until: nil,
                     baseline_resolution_digest: nil, idempotency_key:)
        @organization = organization
        @actor = actor
        @fee_schedule_version = fee_schedule_version
        @attributes = {
          assignment_type:, reason:, effective_from:, event_id: event&.id,
          program_id: program&.id, effective_until:, baseline_resolution_digest:
        }
        @event = event
        @program = program
        @idempotency_key = idempotency_key
      end

      def call
        return failure(unauthorized_error("commercial.draft")) unless actor&.has_permission?("commercial.draft")

        prepare_request!
        ActiveRecord::Base.transaction do
          replay = replay_assignment
          return replay if replay

          result = Commercial::Assignments::CreateDraft.call(
            organization:, actor:, fee_schedule_version:, assignment_type: attributes[:assignment_type],
            reason: attributes[:reason], effective_from: attributes[:effective_from], event:, program:,
            effective_until: attributes[:effective_until],
            baseline_resolution_digest: attributes[:baseline_resolution_digest]
          )
          return result if result.failure?

          record_creation!(result.value)
          success(result.value)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      end

      private

      attr_reader :organization, :actor, :fee_schedule_version, :attributes, :event, :program,
        :idempotency_key, :key_digest, :request_fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("admin-assignment-create", idempotency_key)
        @request_fingerprint = fingerprint_for(
          action: "create", organization_id: organization.id,
          fee_schedule_version_id: fee_schedule_version.id, actor_id: actor.id, attributes:
        )
      end

      def audit_key
        "commercial-admin-assignment-create-#{key_digest}"
      end

      def replay_assignment
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        status = replay_status(audit_key:, actor:, fingerprint: request_fingerprint)
        return failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict

        assignment = Commercial::Assignment.find_by(id: audit.metadata["record_id"])
        return failure(governance_error("replay_not_found", code: "replay_not_found")) unless assignment

        success(assignment)
      end

      def record_creation!(assignment)
        result = Core::Audit::Record.call(
          audit_key:,
          action: "commercial.assignment.api_created",
          auditable_type: assignment.class.name,
          auditable_id: assignment.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: assignment.attributes.slice(
            "organization_id", "event_id", "fee_schedule_version_id", "assignment_type", "status"
          ),
          metadata: { "record_id" => assignment.id, "request_fingerprint" => request_fingerprint }
        )
        raise result.error if result.failure?
      end
    end
  end
end
