module Events
  class ArtistsController < ::Public::ApplicationController
  include Core::FollowableActions

    def index
      artists = Events::Artist.active.with_attached_profile
      total_count = artists.count if paginated_request?
      artists = paginated_request? ? apply_pagination(artists) : artists.limit(25)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(data: artists, serializer_options: { serializer: Events::Public::ArtistListSerializer }, pagination: pagination)
    end

    def show
      artist = Events::Artist.with_attached_profile.find(params[:id])
      render_success(data: artist, serializer_options: { serializer: Events::Public::ArtistDetailSerializer })
    end

    private

    def followable_class
      Events::Artist
    end
  end
end
