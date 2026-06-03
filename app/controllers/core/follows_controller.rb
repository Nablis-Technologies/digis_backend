module Core
  class FollowsController < Core::ApplicationController
    include Core::Pagination
    include Core::FollowableLookup

    skip_authorization only: %i[following]

    def authorize_action!
      query = action_name == "create" ? :follow? : :unfollow?
      authorize followable, query
    end

    def create
      follow = current_user.active_follows.find_or_create_by(followable: followable) do |f|
        f.followed_at = Time.current
      end
      return render_error(errors: follow.errors, status: :unprocessable_entity) unless follow.persisted?

      render_success(:"follow.success.create", data: { following: true, follower_count: followable.reload.followers_count })
    end

    def destroy
      current_user.active_follows.find_by!(followable: followable).destroy!
      render_success(:"follow.success.destroy", data: { following: false, follower_count: followable.reload.followers_count })
    end

    def following
      user = Core::User.find(params[:user_id])
      authorize user, :following?, policy_class: Core::FollowPolicy
      following = user.active_follows.includes(:followable, :follower)
      following = paginated_request? ? apply_pagination(following) : following.limit(25)
      render_success(:"follow.success.following", data: following)
    end
  end
end
