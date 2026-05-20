module Core
  class Role < Core::ApplicationRecord
    include Core::AuditableModel

    has_many :user_roles,
             class_name: "Core::UserRole",
             foreign_key: :role_id,
             dependent: :destroy,
             inverse_of: :role
    has_many :users,
             through: :user_roles,
             class_name: "Core::User"

    has_many :role_permissions,
             class_name: "Core::RolePermission",
             foreign_key: :role_id,
             dependent: :destroy,
             inverse_of: :role
    has_many :permissions,
             through: :role_permissions,
             class_name: "Core::Permission"

    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }

    validates :code, presence: true, uniqueness: true
    validates :name, presence: true

    def self.ransackable_attributes(_auth_object = nil)
      %w[id code name active created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[permissions users]
    end

    before_validation :normalize_code

    private

    def normalize_code
      self.code = code.to_s.strip.upcase.presence
    end
  end
end
