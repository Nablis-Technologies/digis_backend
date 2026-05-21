module Core
  class AuthService < Core::BaseService
    def initialize(operation:, **params)
      @operation = operation.to_sym
      @params = params
    end

    def call
      case @operation
      when :authenticate_user
        user = self.class.authenticate_user(@params[:identifier], @params[:password])
        return Result.success(user) if user.present?

        Result.failure(Core::AuthenticationError.new("Invalid credentials", code: "invalid_credentials"))
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
    rescue Core::Error => error
      Result.failure(error)
    end

    class << self
      def authenticate_user(identifier, password)
        user = find_user_by_identifier(identifier)
        return nil unless user&.authenticate(password)

        user
      end

      def generate_auth_tokens(user, request)
        refresh_token = create_refresh_token(user, request)
        access_token = Core::TokenService.issue(
          Core::TokenService.access_token_payload(user, jti: refresh_token.jti)
        )

        {
          access_token: access_token,
          refresh_token: refresh_token.raw_token,
          user: user
        }
      end

      def refresh_access_token(refresh_token_value, request)
        refresh_token = Core::RefreshToken.find_valid(refresh_token_value)
        raise Core::AuthenticationError.new("Invalid token", code: "invalid_token") unless refresh_token

        validate_device!(refresh_token, request)

        ActiveRecord::Base.transaction do
          old_device_id = refresh_token.device_id
          user = refresh_token.user

          new_refresh = create_refresh_token(user, request)
          new_refresh.update!(device_id: old_device_id)

          refresh_token.revoke!

          access_token = Core::TokenService.issue(
            Core::TokenService.access_token_payload(user, jti: new_refresh.jti)
          )

          {
            access_token: access_token,
            refresh_token: new_refresh.raw_token,
            user: user
          }
        end
      end

      def revoke_refresh_token(token_value)
        Core::RefreshToken.find_valid(token_value)&.revoke!
      end

      def revoke_all_user_tokens(user)
        user.refresh_tokens.active.find_each(&:revoke!)
      end

      private

      def find_user_by_identifier(identifier)
        value = identifier.to_s.strip
        return if value.blank?

        if value.include?("@")
          Core::User.find_by(email: value.downcase)
        else
          Core::User.find_by(phone: value)
        end
      end

      def create_refresh_token(user, request)
        Core::RefreshToken.generate(user, request)
      end

      def validate_device!(refresh_token, request)
        requested_device_id = request.params[:device_id].presence

        # If the stored refresh token is bound to a device, require the request
        # to provide the same device_id. Previously we returned early when the
        # request omitted device_id which allowed replay from other devices.
        if refresh_token.device_id.present?
          unless requested_device_id.present? && requested_device_id.to_s == refresh_token.device_id.to_s
            raise Core::AuthenticationError.new("Refresh token is not valid for this device", code: "invalid_device")
          end
        end
      end
    end
  end
end
