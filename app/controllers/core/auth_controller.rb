module Core
  class AuthController < Core::ApplicationController
    skip_before_action :authenticate_user, only: %i[login signup refresh]
    skip_before_action :authorize_action!, only: %i[login signup refresh]
    before_action :throttle_auth_request, only: %i[login signup refresh]

    def login
      skip_authorization
      auth_result = Core::AuthService.call(
        operation: :authenticate_user,
        identifier: identifier_param,
        password: params[:password]
      )
      user = auth_result.value

      if auth_result.success? && user&.valid_for_authentication?
        auth_user = preloaded_auth_user(user)
        tokens = sign_in(auth_user, request)
        render_success(
          :"auth.success.login",
          data: {
            user: auth_user,
            access_token: tokens[:access_token],
            refresh_token: tokens[:refresh_token]
          },
          serializer_options: {
            user: { serializer: Core::UserAuthSerializer }
          }
        )
      else
        render_error(:"auth.errors.invalid_credentials", status: :unauthorized, code: "invalid_credentials")
      end
    end

    def signup
      skip_authorization
      user = Core::User.new(user_params)
      return render_error(
        I18n.t("auth.errors.signup"),
        errors: [ I18n.t("auth.errors.password_required") ],
        status: :unprocessable_entity,
        code: "signup_failed"
      ) if user.password.blank?

      begin
        ActiveRecord::Base.transaction do
          user.save!
          assign_default_role(user)
        end

        render_success(
          :"auth.success.signup",
          data: {
            user: preloaded_auth_user(user)
          },
          status: :created,
          serializer_options: {
            user: { serializer: Core::UserAuthSerializer }
          }
        )
      rescue ActiveRecord::RecordInvalid => e
        render_error(
          :"auth.errors.signup",
          errors: e.record.errors.full_messages,
          status: :unprocessable_entity,
          code: "signup_failed"
        )
      rescue StandardError => e
        Rails.logger.error "Signup error: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}" if defined?(Rails)
        render_error(
          :"auth.errors.signup",
          errors: [ I18n.t("auth.errors.signup") ],
          status: :internal_server_error,
          code: "signup_failed"
        )
      end
    end

    def logout
      sign_out
      render_success(:"auth.success.logout")
    end

    def me
      skip_authorization
      render_success(
        :"auth.success.me",
        data: {
          user: preloaded_auth_user(current_user)
        },
        serializer_options: {
          user: { serializer: Core::UserAuthSerializer }
        }
      )
    end

    def reauthenticate
      skip_authorization
      response.set_header("Cache-Control", "no-store")

      result = Core::Reauthentication::Issue.call(
        user: current_user,
        session_jti: current_authentication_jti,
        purpose: params[:purpose].presence || Core::ReauthenticationProof::PURPOSES.first,
        password: params.require(:password),
        ip_address: request.remote_ip
      )
      return render_error(result.error.message, status: result.error.status_code, code: result.error.code) if result.failure?

      render_success(:"reauthentication.success.issued", data: { proof: result.value })
    end

    def refresh
      skip_authorization
      new_tokens = refresh_token!

      render_success(
        :"auth.success.refresh",
        data: {
          access_token: new_tokens[:access_token],
          refresh_token: new_tokens[:refresh_token],
          user: preloaded_auth_user(new_tokens[:user])
        },
        serializer_options: {
          user: { serializer: Core::UserAuthSerializer }
        }
      )
    rescue Core::AuthenticationError => e
      render_error(:"auth.errors.#{e.code}", status: :unauthorized, code: e.code)
    end

    private

    def user_params
      params.require(:user).permit(
        :email,
        :phone,
        :password,
        :password_confirmation
      )
    end

    def identifier_param
      params[:identifier]
    end

    def preloaded_auth_user(user)
      return user unless user.is_a?(Core::User)

      unless user.association(:roles).loaded?
        ActiveRecord::Associations::Preloader.new(records: [ user ], associations: { roles: :permissions }).call
      end
      user
    end

    def throttle_auth_request
      result = Core::AuthThrottle.call(
        identifier: params[:identifier].presence || params.dig(:user, :email).presence ||
          params.dig(:user, :phone).presence || params[:refresh_token],
        ip_address: request.remote_ip
      )
      return if result.success?

      render_error(result.error.message, status: result.error.status_code, code: result.error.code)
    end

    def assign_default_role(user)
      role = Core::Role.find_or_create_by!(code: "USER") do |record|
        record.name = "User"
        record.description = "Default end-user role"
        record.active = true
      end

      Core::UserRole.find_or_create_by!(user: user, role: role)
    end
  end
end
