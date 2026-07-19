# frozen_string_literal: true

module Core
  module AuditableModel
    extend ActiveSupport::Concern

    included do
      # No dependent: :destroy — audit history must survive deletion of the
      # audited record (captured polymorphic type/id is enough to reconstruct it).
      has_many :audit_logs, as: :auditable, class_name: "Core::AuditLog"
    end

    # Synchronous path: write evidence inside the caller's transaction. Returns
    # the created/found Core::AuditLog. Use this for commands that must roll back
    # with their business transaction.
    def record_audit!(action_name, audited_changes: {}, metadata: {}, actor: nil, request_uuid: nil,
      ip_address: nil, user_agent: nil, audit_key: nil)
      key = audit_key || "model:#{self.class.name}:#{id}:#{action_name}:#{SecureRandom.uuid}"

      Core::Audit::Record.call(
        audit_key: key,
        action: action_name,
        auditable_type: self.class.name,
        auditable_id: id,
        actor_type: actor&.class&.name,
        actor_id: actor&.id,
        audited_changes: audited_changes.presence || {},
        metadata: metadata.presence || {},
        request_uuid: request_uuid,
        ip_address: ip_address,
        user_agent: user_agent
      ).value
    end

    # Async path: enqueue the normalized payload; the job writes via the same
    # single recorder. Auto-generates a random key because these convenience
    # calls have no external idempotency identity.
    def record_audit_later!(action_name, audited_changes: {}, metadata: {}, actor: nil, request_uuid: nil,
      ip_address: nil, user_agent: nil, audit_key: nil)
      key = audit_key || "model:#{self.class.name}:#{id}:#{action_name}:#{SecureRandom.uuid}"

      Core::AuditLoggerJob.perform_later(
        audit_key: key,
        action: action_name,
        auditable_type: self.class.name,
        auditable_id: id,
        actor_type: actor&.class&.name,
        actor_id: actor&.id,
        audited_changes: audited_changes.presence || {},
        metadata: metadata.presence || {},
        request_uuid: request_uuid,
        ip_address: ip_address,
        user_agent: user_agent
      )
    end

    def audit_history(limit: 50)
      audit_logs.recent.limit(limit)
    end

    def last_audit
      audit_logs.recent.first
    end
  end
end
