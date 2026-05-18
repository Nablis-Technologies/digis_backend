module Platform
  module AuditableModel
    extend ActiveSupport::Concern

    included do
      has_many :audit_logs,
               as: :auditable,
               class_name: "Platform::AuditLog",
               dependent: :destroy
    end

    def record_audit!(action_name, audited_changes: {}, metadata: {}, actor: nil, request_uuid: nil, ip_address: nil, user_agent: nil)
      audit_logs.create!(
        action: action_name,
        audited_changes: audited_changes.presence || {},
        metadata: metadata.presence || {},
        actor: actor,
        request_uuid: request_uuid,
        ip_address: ip_address,
        user_agent: user_agent
      )
    end

    def record_audit_later!(action_name, audited_changes: {}, metadata: {}, actor: nil, request_uuid: nil, ip_address: nil, user_agent: nil)
      Platform::AuditLoggerJob.perform_later(
        auditable_type: self.class.name,
        auditable_id: id,
        action: action_name,
        audited_changes: audited_changes.presence || {},
        metadata: metadata.presence || {},
        actor_type: actor&.class&.name,
        actor_id: actor&.id,
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
