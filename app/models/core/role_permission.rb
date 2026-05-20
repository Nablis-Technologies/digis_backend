module Core
  class RolePermission < Core::ApplicationRecord
    belongs_to :role,
               class_name: "Core::Role",
               inverse_of: :role_permissions
    belongs_to :permission,
               class_name: "Core::Permission",
               inverse_of: :role_permissions

    validates :permission_id, uniqueness: { scope: :role_id, message: "already assigned to this role" }
  end
end
