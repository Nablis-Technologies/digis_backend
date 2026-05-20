module Core
  class RoleSerializer < ActiveModel::Serializer
    attributes :id, :code, :name, :description, :active, :created_at, :updated_at

    has_many :permissions, serializer: Core::PermissionSerializer
  end
end
