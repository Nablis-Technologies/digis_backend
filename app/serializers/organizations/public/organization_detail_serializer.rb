module Organizations
  module Public
    class OrganizationDetailSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      include Rails.application.routes.url_helpers

      attributes :id, :name, :slug, :description, :social_links,
                 :organizer_type, :category,
                 :contact_phone, :contact_email, :website_url,
                 :city, :region,
                 :estimated_audience, :event_frequency,
                 :events_count, :follower_count,
                 :verified, :is_following,
                 :created_at

      attribute :follower_count do
        object.followers_count
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

      attribute :business_license_url do
        object.business_license.attached? ? url_for(object.business_license) : nil
      end

      attribute :tin_certificate_url do
        object.tin_certificate.attached? ? url_for(object.tin_certificate) : nil
      end
    end
  end
end
