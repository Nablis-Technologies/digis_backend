# frozen_string_literal: true

module Core
  class UserProfileSerializer < ActiveModel::Serializer
    attributes :first_name, :last_name, :full_name, :avatar_url

    def avatar_url
      object.avatar.attached? ? "/user/avatar" : nil
    end
  end
end
