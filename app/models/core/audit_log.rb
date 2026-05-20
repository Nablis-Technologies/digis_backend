module Core
  class AuditLog < Core::ApplicationRecord
    belongs_to :auditable, polymorphic: true
    belongs_to :actor, polymorphic: true, optional: true

    validates :action, presence: true

    scope :for_auditable, ->(record) { where(auditable_type: record.class.name, auditable_id: record.id) }
    scope :by_actor, ->(actor) { where(actor_type: actor.class.name, actor_id: actor.id) }
    scope :for_action, ->(name) { where(action: name.to_s) }
    scope :recent, -> { order(created_at: :desc) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id action auditable_type auditable_id actor_type actor_id request_uuid ip_address created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[auditable actor]
    end
  end
end
