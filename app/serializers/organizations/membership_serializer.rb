module Organizations
  class MembershipSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    attributes :id, :role, :created_at
    belongs_to :user, serializer: Core::UserAuthSerializer
  end
end
