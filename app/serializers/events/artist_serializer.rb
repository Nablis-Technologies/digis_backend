class Events::ArtistSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :genres, :social_links,
             :verified, :active, :created_at, :updated_at

  attribute :profile_url do
    if object.profile.attached?
      url_for(object.profile)
    else
      object[:image_url]
    end
  end

  attribute :profile_urls do
    if object.profile.attached?
      {
        original: url_for(object.profile),
        thumbnail: url_for(object.profile.variant(resize_to_fill: [ 300, 300 ])),
        medium: url_for(object.profile.variant(resize_to_fill: [ 800, 800 ]))
      }
    else
      { original: object[:image_url], thumbnail: nil, medium: nil }
    end
  end

  attribute :follower_count do
    object.followers_count
  end
end
