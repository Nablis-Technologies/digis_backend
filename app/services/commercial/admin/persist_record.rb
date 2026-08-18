# frozen_string_literal: true

module Commercial
  module Admin
    # Persists only controller-allowlisted draft resources with the same audit,
    # outbox, and replay contract as Commercial lifecycle commands. It is not a
    # generic model writer: callers construct the approved model and attributes
    # before invoking this command.
    class PersistRecord < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(record:, actor:, attributes:, idempotency_key:, action:, permission: "commercial.draft")
        @record = record
        @actor = actor
        @attributes = attributes.to_h.deep_symbolize_keys
        @idempotency_key = idempotency_key
        @action = action.to_s
        @permission = permission.to_s
      end

      def call
        return failure(unauthorized_error(permission)) unless actor&.has_permission?(permission)

        prepare_request!
        ActiveRecord::Base.transaction do
          replay = replay_record
          return replay if replay

          persist_record!
          record_transition!
          success(record)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          governance_error(
            "invalid_record", code: "invalid_record", errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :record, :actor, :attributes, :idempotency_key, :action, :permission,
        :key_digest, :request_fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("admin-#{record.model_name.element}-#{action}", idempotency_key)
        @request_fingerprint = fingerprint_for(
          action:, record_type: record.class.name, record_id: record.id,
          actor_id: actor.id, attributes:
        )
      end

      def audit_key
        "commercial-admin-#{record.model_name.element}-#{action}-#{key_digest}"
      end

      def replay_record
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        status = replay_status(audit_key:, actor:, fingerprint: request_fingerprint)
        return failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict

        target_id = audit.metadata["record_id"]
        target = record.class.find_by(id: target_id)
        return failure(governance_error("replay_not_found", code: "replay_not_found")) unless target

        success(target)
      end

      def persist_record!
        record.assign_attributes(attributes)
        record.save!
      end

      def record_transition!
        transition = record.previous_changes.slice(*attributes.keys.map(&:to_s), "created_at", "updated_at")
        super(
          target: record,
          actor:,
          audit_key:,
          action: "commercial.#{record.model_name.element}.#{action}",
          audited_changes: transition,
          metadata: { "record_id" => record.id, "request_fingerprint" => request_fingerprint },
          topic: "commercial",
          event_type: "commercial.#{record.model_name.element}.#{action}",
          payload: { record_type: record.class.name, record_id: record.id, action: }
        )
      end
    end
  end
end
