module Core
  class FollowersController < Core::ApplicationController
    include Core::Pagination
    include Core::FollowableLookup

    skip_before_action :authenticate_user, only: %i[index]
    skip_authorization

    def index
      followers = paginated_request? ? apply_pagination(followable.followers) : followable.followers.limit(25)
      render_success(data: followers, serializer_options: { serializer: Core::Public::UserSerializer })
    end
  end
end
