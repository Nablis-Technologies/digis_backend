module Core
  class Permission < Core::ApplicationRecord
    include Core::AuditableModel

    has_many :role_permissions,
             class_name: "Core::RolePermission",
             foreign_key: :permission_id,
             dependent: :destroy,
             inverse_of: :permission
    has_many :roles,
             through: :role_permissions,
             class_name: "Core::Role"

    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }
    scope :by_resource, ->(resource) { where(resource: resource.to_s) }
    scope :by_namespace, ->(namespace) { where(namespace: namespace.to_s) }

    validates :code, presence: true, uniqueness: { case_sensitive: false }
    validates :resource, presence: true
    validates :action, presence: true
    validates :namespace, presence: true
    validates :resource, uniqueness: {
      scope: %i[action namespace],
      message: ->(*_args) { I18n.t("permission.errors.action_namespace_already_exists") }
    }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id code resource action namespace active created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[roles]
    end

    before_validation :normalize_fields
    before_validation :set_default_code

    private

    def normalize_fields
      self.resource = resource.to_s.strip.underscore.presence
      self.action = action.to_s.strip.underscore.presence
      self.namespace = namespace.to_s.strip.underscore.presence
      self.code = code.to_s.strip.presence
    end

    def set_default_code
      self.code ||= "#{resource}.#{action}"
    end
  end
end
