module Events
  class VenuesController < ::Public::ApplicationController
  include Core::FollowableActions

    def index
      venues = Events::Venue.active.with_attached_profile.with_attached_photos
      total_count = venues.count if paginated_request?
      venues = paginated_request? ? apply_pagination(venues) : venues.limit(25)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(data: venues, serializer_options: { serializer: Events::Public::VenueListSerializer }, pagination: pagination)
    end

    def show
      venue = Events::Venue.with_attached_profile.with_attached_photos.find(params[:id])
      render_success(data: venue, serializer_options: { serializer: Events::Public::VenueDetailSerializer })
    end

    private

    def followable_class
      Events::Venue
    end
  end
end
