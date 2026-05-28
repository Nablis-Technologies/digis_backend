module Admin
  class PermissionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :code, :resource, :action, :namespace, :description, :active, :created_at, :updated_at
  end
end
