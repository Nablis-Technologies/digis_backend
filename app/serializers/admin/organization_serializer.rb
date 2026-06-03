module Admin
  class OrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    include Rails.application.routes.url_helpers

    attributes :id, :name, :slug, :description, :social_links,
               :followers_count, :created_at, :updated_at, :profile_url,
               :memberships_count

    has_one :owner, serializer: ::Admin::UserSerializer

    def profile_url
      object.profile.attached? ? url_for(object.profile) : nil
    end

    def memberships_count
      object.memberships.size
    end
  end
end
