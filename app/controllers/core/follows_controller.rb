module Core
  class FollowsController < Core::ApplicationController
    include Core::Pagination

    skip_authorization only: [ :following ]

    def following
      user = Core::User.find(params[:user_id])
      authorize user, :following?, policy_class: Core::FollowPolicy
      following = user.active_follows.includes(:followable, :follower)
      following = paginated_request? ? apply_pagination(following) : following.limit(25)
      render_success(data: following)
    end
  end
end
