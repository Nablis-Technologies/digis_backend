module Platform
  class AuthService < Platform::BaseService
    def initialize(operation:, **params)
      @operation = operation.to_sym
      @params = params
    end

    def call
      case @operation
      when :authenticate_user
        user = self.class.authenticate_user(@params[:identifier], @params[:password])
        return Result.success(user) if user.present?

        Result.failure(Platform::AuthenticationError.new("Invalid credentials", code: "invalid_credentials"))
      when :generate_auth_tokens
        Result.success(self.class.generate_auth_tokens(@params[:user], @params[:request]))
      when :refresh_access_token
        Result.success(self.class.refresh_access_token(@params[:refresh_token_value], @params[:request]))
      when :revoke_refresh_token
        Result.success(self.class.revoke_refresh_token(@params[:token_value]))
      when :revoke_all_user_tokens
        Result.success(self.class.revoke_all_user_tokens(@params[:user]))
      else
        raise ArgumentError, "Unsupported auth operation: #{@operation}"
      end
    rescue Platform::Error => error
      Result.failure(error)
    end

    class << self
      def authenticate_user(identifier, password)
        user = find_user_by_identifier(identifier)
        return nil unless user&.authenticate(password)

        user
      end

      def generate_auth_tokens(user, request)
        access_token = Platform::TokenService.issue(Platform::TokenService.access_token_payload(user))
        refresh_token = create_refresh_token(user, request)

        {
          access_token: access_token,
          refresh_token: refresh_token,
          user: user
        }
      end

      def refresh_access_token(refresh_token_value, request)
        refresh_token = Platform::RefreshToken.active.find_by(refresh_token: refresh_token_value)
        raise Platform::AuthenticationError.new("Invalid token", code: "invalid_token") unless refresh_token

        validate_device!(refresh_token, request)

        # Rotate: destroy old, create new
        old_device_id = refresh_token.device_id
        user = refresh_token.user
        refresh_token.destroy

        access_token = Platform::TokenService.issue(
          Platform::TokenService.access_token_payload(user)
        )
        new_refresh = create_refresh_token(user, request)
        new_refresh.update!(device_id: old_device_id)  # preserve device binding

        {
          access_token: access_token,
          refresh_token: new_refresh.refresh_token,
          user: user
        }
      end

      def revoke_refresh_token(token_value)
        Platform::RefreshToken.find_by(refresh_token: token_value)&.destroy
      end

      def revoke_all_user_tokens(user)
        user.refresh_tokens.destroy_all
      end

      private

      def find_user_by_identifier(identifier)
        value = identifier.to_s.strip
        return if value.blank?

        if value.include?("@")
          Platform::User.find_by(email: value.downcase)
        else
          Platform::User.find_by(phone: value)
        end
      end

      def create_refresh_token(user, request)
        Platform::RefreshToken.generate(user, request)
      end

      def validate_device!(refresh_token, request)
        requested_device_id = request.params[:device_id].presence
        return if requested_device_id.blank? || refresh_token.device_id.blank?
        return if requested_device_id == refresh_token.device_id

        raise Platform::AuthenticationError.new("Refresh token is not valid for this device", code: "invalid_device")
      end
    end
  end
end
