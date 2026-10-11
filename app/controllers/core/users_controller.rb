# frozen_string_literal: true

module Core
  class UsersController < Core::ApplicationController
    include Core::CurrentUserPreloading

    before_action :ensure_idempotency_key_present, only: :update

    def show
      response.set_header("Cache-Control", "private, no-store")
      render_success(
        data: preload_current_user(current_user),
        serializer_options: { serializer: Core::CurrentUserSerializer }
      )
    end

    def update
      response.set_header("Cache-Control", "private, no-store")
      result = Core::UserProfiles::Update.call(
        user: current_user,
        attributes: profile_params,
        idempotency_key:,
        request:
      )
      return render_service_result(result) if result.failure?

      render_success(
        data: preload_current_user(result.value.user),
        serializer_options: { serializer: Core::CurrentUserSerializer }
      )
    end

    def avatar
      response.set_header("Cache-Control", "no-store")
      profile = Core::UserProfile.with_attached_avatar.find_by(user_id: current_user.id)
      return render_error(avatar_not_found_message, status: :not_found, code: "avatar_not_found") unless
        profile&.avatar&.attached?

      fresh_when(etag: avatar_etag(profile), public: false)
      response.set_header("Cache-Control", "private, max-age=0, must-revalidate")
      return if performed?

      thumbnail = profile.avatar.variant(:thumb).processed
      send_data thumbnail.download, type: profile.avatar.blob.content_type, disposition: "inline"
    rescue StandardError => exception
      Rails.logger.error(
        "profile avatar delivery failed error_class=#{exception.class.name} request_id=#{request.request_id}"
      )
      response.set_header("Cache-Control", "no-store")
      render_error(I18n.t("user.errors.avatar_unavailable"), status: :service_unavailable, code: "avatar_unavailable")
    end

    private

    def profile_params
      params.require(:profile).permit(:first_name, :last_name, :avatar, :remove_avatar)
    end

    def policy_target_for_authorization
      current_user
    end

    def avatar_etag(profile)
      blob = profile.avatar.blob
      Core::KeyedDigest.digest(
        namespace: "core/user/avatar-etag/#{profile.id}",
        value: [ current_user.id, profile.id, blob.id, blob.checksum, blob.byte_size ].join(":")
      )
    end

    def avatar_not_found_message
      I18n.t("user.errors.avatar_not_found")
    end
  end
end
