class Events::Public::ArtistListSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :genres, :verified, :active

  attribute :profile_url do
    if object.profile.attached?
      url_for(object.profile.variant(resize_to_fill: [ 300, 300 ]))
    else
      object[:image_url]
    end
  end
end
