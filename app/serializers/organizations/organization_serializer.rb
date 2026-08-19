module Organizations
  class OrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    include Rails.application.routes.url_helpers

    attributes :id, :name, :slug, :description, :social_links,
               :organizer_type, :category,
               :contact_phone, :contact_email, :website_url,
               :tin_number, :address_line1, :address_line2, :city, :region,
               :estimated_audience, :event_frequency,
               :events_count, :follower_count, :memberships_count,
                :verified, :is_following,
               :created_at

    attribute :follower_count do
      object.followers_count
    end

    attribute :memberships_count do
      object.memberships.size
    end

    attribute :verified do
      object.verified?
    end

    attribute :is_following do
      if instance_options[:current_user]
        object.followed_by?(instance_options[:current_user])
      else
        false
      end
    end

    attribute :profile_url do
      object.profile.attached? ? url_for(object.profile) : nil
    end

    attribute :banner_url do
      object.banner.attached? ? url_for(object.banner) : nil
    end
  end
end
