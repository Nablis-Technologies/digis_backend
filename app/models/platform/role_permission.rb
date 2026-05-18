module Platform
  class RolePermission < Platform::ApplicationRecord
    belongs_to :role,
               class_name: "Platform::Role",
               inverse_of: :role_permissions
    belongs_to :permission,
               class_name: "Platform::Permission",
               inverse_of: :role_permissions

    validates :permission_id, uniqueness: { scope: :role_id, message: "already assigned to this role" }
  end
end
