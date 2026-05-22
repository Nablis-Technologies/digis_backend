module Events
  class CategorySerializer < ActiveModel::Serializer
    attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
    has_many :audit_logs, serializer: Core::AuditLogSerializer
  end
end
