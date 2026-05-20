module Core
  module TokenAuthenticatable
    extend ActiveSupport::Concern

    def require_valid_refresh_token
      refresh_token_value = params[:refresh_token]
      return if refresh_token_value.present? && Core::RefreshToken.active.exists?(refresh_token: refresh_token_value)

      raise Core::AuthenticationError.new("Valid refresh token required", code: "valid_refresh_token_required")
    end
  end
end
