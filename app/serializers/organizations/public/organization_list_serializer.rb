module Organizations
  module Public
    class OrganizationListSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      include Rails.application.routes.url_helpers

      attributes :id, :name, :slug, :description,
                 :organizer_type, :category,
                 :city, :region,
                 :events_count, :follower_count,
                 :verified,
                 :created_at

      attribute :follower_count do
        object.followers_count
      end

      attribute :verified do
        object.verified?
      end

      attribute :profile_url do
        object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [ 300, 300 ])) : nil
      end

      attribute :banner_url do
        object.banner.attached? ? url_for(object.banner.variant(resize_to_fill: [ 1200, 400 ])) : nil
      end
    end
  end
end
