module Core
  class UserAuthSerializer < ActiveModel::Serializer
    attributes :id, :email, :phone, :verified_at, :created_at, :updated_at, :permissions

    has_many :roles, serializer: Core::RoleSerializer

    def permissions
      object.active_permissions.to_a
    end
  end
end
