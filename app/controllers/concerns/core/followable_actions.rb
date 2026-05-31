module Core
  module FollowableActions
    extend ActiveSupport::Concern

    included do
      before_action :authenticate_user, only: [ :follow, :unfollow ]
    end

    def follow
      record = followable_class.find(params[:id])
      follow = current_user.active_follows.find_or_create_by(followable: record) do |f|
        f.followed_at = Time.current
      end
      return render_error(errors: follow.errors, status: :unprocessable_entity) unless follow.persisted?

      render_success(data: { following: true, follower_count: record.reload.followers_count })
    end

    def unfollow
      record = followable_class.find(params[:id])
      current_user.active_follows.find_by!(followable: record).destroy!
      render_success(data: { following: false, follower_count: record.reload.followers_count })
    end

    def followers
      record = followable_class.find(params[:id])
      followers = paginated_request? ? apply_pagination(record.followers) : record.followers.limit(25)
      render_success(data: followers, serializer_options: { serializer: Core::Public::UserSerializer })
    end

    private

    def followable_class
      raise NotImplementedError, "#{self.class.name} must define #followable_class"
    end
  end
end
