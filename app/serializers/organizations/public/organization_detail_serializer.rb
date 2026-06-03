module Organizations
  module Public
    class OrganizationDetailSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      include Rails.application.routes.url_helpers

      attributes :id, :name, :slug, :description, :social_links, :created_at

      attribute :profile_url do
        object.profile.attached? ? url_for(object.profile) : nil
      end

      attribute :follower_count do
        object.followers_count
      end
    end
  end
end
