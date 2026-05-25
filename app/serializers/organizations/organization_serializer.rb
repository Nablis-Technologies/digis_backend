module Organizations
  class OrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    attributes :id, :name, :slug, :description, :created_at
    has_many :memberships, serializer: Organizations::MembershipSerializer
  end
end
