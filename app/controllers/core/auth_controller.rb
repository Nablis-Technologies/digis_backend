module Core
  class AuthController < Core::ApplicationController
    include Core::CurrentUserPreloading

    skip_before_action :authenticate_user, only: %i[login signup signup_request_otp refresh]
    skip_before_action :authorize_action!, only: %i[login signup signup_request_otp refresh]
    before_action :throttle_auth_request, only: %i[login signup signup_request_otp refresh]
    before_action :ensure_idempotency_key_present, only: %i[signup signup_request_otp]

    def login
      skip_authorization
      auth_result = Core::AuthService.call(
        operation: :authenticate_user,
        identifier: identifier_param,
        password: params[:password]
      )
      user = auth_result.value

      if auth_result.success? && user&.valid_for_authentication?
        auth_user = preload_current_user(user)
        tokens = sign_in(auth_user, request)
        render_success(
          :"auth.success.login",
          data: {
            user: auth_user,
            access_token: tokens[:access_token],
            refresh_token: tokens[:refresh_token]
          },
          serializer_options: {
            user: { serializer: Core::CurrentUserSerializer }
          }
        )
      else
        record_auth_failure
        render_error(:"auth.errors.invalid_credentials", status: :unauthorized, code: "invalid_credentials")
      end
    end

    def signup
      skip_authorization
      response.set_header("Cache-Control", "no-store")
      result = Core::Signups::Complete.call(
        attributes: user_params,
        verification_token: params[:verification_token],
        idempotency_key:,
        request:
      )
      if result.failure?
        record_auth_failure
        return render_service_result(result)
      end

      render_success(
        :"auth.success.signup",
        data: {
          user: preload_current_user(result.value.user),
          access_token: result.value.access_token,
          refresh_token: result.value.refresh_token
        },
        status: :created,
        serializer_options: {
          user: { serializer: Core::CurrentUserSerializer }
        }
      )
    end

    def signup_request_otp
      skip_authorization
      response.set_header("Cache-Control", "no-store")
      attempt = auth_throttle.record_attempt
      return render_service_result(attempt) if attempt.failure?

      result = Core::Signups::RequestOtp.call(phone: params[:phone], idempotency_key:)
      return render_service_result(result) if result.failure?

      challenge = result.value
      render_success(
        data: {
          challenge_id: challenge.id,
          status: challenge.status,
          expires_at: challenge.expires_at
        },
        status: :created
      )
    end

    def logout
      sign_out
      render_success(:"auth.success.logout")
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
          user: preload_current_user(new_tokens[:user])
        },
        serializer_options: {
          user: { serializer: Core::CurrentUserSerializer }
        }
      )
    rescue Core::AuthenticationError => e
      record_auth_failure
      render_error(:"auth.errors.#{e.code}", status: :unauthorized, code: e.code)
    end

    private

    def user_params
      params.require(:user).permit(
        :email,
        :phone,
        :first_name,
        :last_name,
        :password,
        :password_confirmation
      )
    end

    def identifier_param
      params[:identifier]
    end

    def throttle_auth_request
      result = auth_throttle.call
      return if result.success?

      render_error(result.error.message, status: result.error.status_code, code: result.error.code)
    end

    def record_auth_failure
      auth_throttle.record_failure
    end

    def auth_throttle
      @auth_throttle ||= Core::AuthThrottle.new(
        identifier: auth_throttle_identifier,
        ip_address: request.remote_ip
      )
    end

    def auth_throttle_identifier
      case action_name
      when "signup_request_otp"
        normalized_or_raw_phone(params[:phone])
      when "signup"
        phone = params.dig(:user, :phone).presence || params[:phone].presence
        normalized_or_raw_phone(phone) || params.dig(:user, :email)
      else
        params[:identifier].presence || params.dig(:user, :email).presence ||
          params.dig(:user, :phone).presence || params[:phone].presence || params[:refresh_token]
      end
    end

    def normalized_or_raw_phone(phone)
      return if phone.blank?

      Core::PhoneIdentity::ResolveOrCreate.normalize(phone) || phone
    end
  end
end
