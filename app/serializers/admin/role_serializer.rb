module Admin
  class RoleSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :code, :name, :description, :active, :created_at, :updated_at

    has_many :permissions, serializer: ::Admin::PermissionSerializer
  end
end
