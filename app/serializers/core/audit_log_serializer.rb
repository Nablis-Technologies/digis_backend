module Core
  class AuditLogSerializer < ActiveModel::Serializer
    attributes :id, :action, :audited_changes, :metadata, :request_uuid, :ip_address, :user_agent, :created_at, :updated_at
    attribute :actor
    attribute :auditable

    def actor
      return nil unless object.actor

      {
        id: object.actor.id,
        type: object.actor_type,
        name: actor_display_name(object.actor)
      }
    end

    def auditable
      {
        id: object.auditable_id,
        type: object.auditable_type
      }
    end

    private

    def actor_display_name(actor_record)
      return actor_record.full_name if actor_record.respond_to?(:full_name) && actor_record.full_name.present?
      return actor_record.name if actor_record.respond_to?(:name) && actor_record.name.present?
      return actor_record.email if actor_record.respond_to?(:email) && actor_record.email.present?

      "#{actor_record.class.name.demodulize} ##{actor_record.id}"
    end
  end
end
