module Core
  module Public
    class UserSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      attributes :id, :created_at
    end
  end
end
