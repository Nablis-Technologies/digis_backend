module Platform
  class PermissionSerializer < ActiveModel::Serializer
    attributes :id, :code, :resource, :action, :namespace, :description, :active
  end
end
