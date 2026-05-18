module Platform
  module TokenAuthenticatable
    extend ActiveSupport::Concern

    def require_valid_refresh_token
      refresh_token_value = params[:refresh_token]
      return if refresh_token_value.present? && Platform::RefreshToken.active.exists?(refresh_token: refresh_token_value)

      raise Platform::AuthenticationError.new("Valid refresh token required", code: "valid_refresh_token_required")
    end
  end
end
