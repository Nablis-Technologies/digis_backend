module Admin
  class UserSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :email, :phone, :verified_at, :deactivated_at, :deactivated_reason, :created_at, :updated_at

    has_many :roles, serializer: ::Admin::RoleSerializer
  end
end
