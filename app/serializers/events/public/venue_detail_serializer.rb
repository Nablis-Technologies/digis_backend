class Events::Public::VenueDetailSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :address, :city, :country,
             :latitude, :longitude, :capacity, :amenities, :social_links,
             :contact_phone, :contact_email, :website_url,
             :verified, :active

  attribute :profile_url do
    object.profile.attached? ? url_for(object.profile) : nil
  end

  attribute :profile_urls do
    {
      original: object.profile.attached? ? url_for(object.profile) : nil,
      thumbnail: object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [ 300, 300 ])) : nil,
      medium: object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [ 800, 800 ])) : nil
    }
  end

  attribute :gallery_urls do
    object.photos.map do |photo|
      {
        original: url_for(photo),
        thumbnail: url_for(photo.variant(resize_to_fill: [ 300, 300 ])),
        medium: url_for(photo.variant(resize_to_fill: [ 800, 800 ]))
      }
    end
  end

  attribute :follower_count do
    object.followers_count
  end
end
