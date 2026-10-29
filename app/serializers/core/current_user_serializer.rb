# frozen_string_literal: true

module Core
  class CurrentUserSerializer < ActiveModel::Serializer
    attributes :id, :email, :phone, :verified_at, :created_at, :updated_at, :permissions

    has_many :roles, serializer: Core::RoleSerializer
    has_one :profile, serializer: Core::UserProfileSerializer

    def permissions
      object.active_permissions.to_a
    end
  end
end
