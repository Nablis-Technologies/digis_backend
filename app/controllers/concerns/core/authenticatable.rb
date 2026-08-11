module Core
  module Authenticatable
    extend ActiveSupport::Concern

    included do
      rescue_from Core::AuthenticationError, with: :handle_authentication_error
    end

    def current_user
      @current_user ||= authenticate_from_token
    end

    # Decode once per request; the proof boundary consumes the same verified JTI.
    def current_authentication_jti
      payload = current_access_token_payload
      payload && (payload["jti"] || payload[:jti])
    end

    def authenticate_user
      raise Core::AuthenticationError.new(I18n.t("auth.errors.authentication_required"), code: "authentication_required") unless current_user
    end

    def sign_in(user, request)
      tokens = user.generate_auth_tokens(request)
      @current_user = user
      tokens
    end

    def sign_out
      refresh_token_value = extract_refresh_token_from_params
      if refresh_token_value.present?
        Core::AuthService.call(operation: :revoke_refresh_token, token_value: refresh_token_value)
      end
      @current_user = nil
      @current_access_token_payload = nil
    end

    def refresh_token!
      refresh_token_value = extract_refresh_token_from_params
      raise Core::AuthenticationError.new(I18n.t("auth.errors.refresh_token_missing"), code: "invalid_token") if refresh_token_value.blank?

      result = Core::AuthService.call(
        operation: :refresh_access_token,
        refresh_token_value: refresh_token_value,
        request: request
      )
      raise result.error if result.failure?

      result.value
    end

    private

    def authenticate_from_token
      payload = current_access_token_payload
      return nil unless payload && (payload["type"] || payload[:type]) == "access"

      Core::User.find_by(id: payload["user_id"] || payload[:user_id])
    end

    def current_access_token_payload
      return @current_access_token_payload if defined?(@current_access_token_payload)

      access_token = extract_access_token_from_header
      @current_access_token_payload = if access_token.blank?
        nil
      else
        Core::TokenService.decode(access_token, verify_revocation: true)
      end
    rescue Core::AuthenticationError
      @current_access_token_payload = nil
    end

    def extract_access_token_from_header
      auth_header = request.headers["Authorization"].to_s
      return nil unless auth_header.start_with?("Bearer ")

      auth_header.split.last
    end

    def extract_refresh_token_from_params
      params[:refresh_token]
    end

    def handle_authentication_error(error)
      if respond_to?(:render_error)
        render_error(error.message, status: error.status_code, code: error.code)
      else
        render json: error.to_h, status: error.status_code
      end
    end
  end
end
