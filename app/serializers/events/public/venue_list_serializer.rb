class Events::Public::VenueListSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :address, :city, :country,
             :capacity, :verified, :active

  attribute :profile_urls do
    {
      thumbnail: object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [ 300, 300 ])) : nil,
      medium: object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [ 800, 800 ])) : nil
    }
  end
end
