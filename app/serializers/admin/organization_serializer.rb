module Admin
  class OrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    include Rails.application.routes.url_helpers

    attributes :id, :name, :slug, :description, :social_links,
               :organizer_type, :category,
               :contact_phone, :contact_email, :website_url,
               :tin_number, :address_line1, :address_line2, :city, :region,
               :estimated_audience, :event_frequency,
                :events_count, :follower_count, :memberships_count,
                :verified,
                :created_at, :updated_at, :profile_url,
               :banner_url, :business_license_url, :tin_certificate_url

    has_one :owner, serializer: ::Admin::UserSerializer

    def profile_url
      object.profile.attached? ? url_for(object.profile) : nil
    end

    def banner_url
      object.banner.attached? ? url_for(object.banner) : nil
    end

    def business_license_url
      object.business_license.attached? ? url_for(object.business_license) : nil
    end

    def tin_certificate_url
      object.tin_certificate.attached? ? url_for(object.tin_certificate) : nil
    end

    def follower_count
      object.followers_count
    end

    def memberships_count
      object.memberships.size
    end

    def verified
      object.verified?
    end
  end
end
