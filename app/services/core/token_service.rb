require "jwt"

module Core
  class TokenService
    class << self
      def issue(payload, expires_in: access_token_expires_in)
        encoded_payload = payload.merge(exp: Time.current.to_i + expires_in.to_i)
        ::JWT.encode(encoded_payload, key, "HS256")
      end

      def decode(token)
        return nil if token.blank?

        decoded = ::JWT.decode(token, key, true, algorithm: "HS256")
        decoded.first
      rescue ::JWT::ExpiredSignature
        raise Core::AuthenticationError.new(I18n.t("auth.errors.token_expired"), code: "token_expired")
      rescue ::JWT::DecodeError
        raise Core::AuthenticationError.new(I18n.t("auth.errors.invalid_token"), code: "invalid_token")
      end

      def access_token_payload(user, jti: nil)
        {
          user_id: user.id,
          jti: jti || SecureRandom.uuid,
          identifier: user.email || user.phone,
          type: "access",
          roles: user.active_role_codes
        }
      end

      def decode(token, verify_revocation: true)
        return nil if token.blank?

        decoded = ::JWT.decode(token, key, true, algorithm: "HS256")
        payload = decoded.first

        if verify_revocation && payload["jti"]
          raise Core::AuthenticationError.new(I18n.t("auth.errors.token_revoked"), code: "token_revoked") if jti_revoked?(payload["jti"])
        end

        payload
      rescue ::JWT::ExpiredSignature
        raise Core::AuthenticationError.new(I18n.t("auth.errors.token_expired"), code: "token_expired")
      rescue ::JWT::DecodeError
        raise Core::AuthenticationError.new(I18n.t("auth.errors.invalid_token"), code: "invalid_token")
      end

      def jti_revoked?(jti)
        Core::RefreshToken.exists?(jti: jti, revoked: true)
      end

      def access_token_expires_in
        15.minutes
      end

      def refresh_token_expires_in
        30.days
      end

      def key
        return @key if defined?(@key)

        @key = ENV["CORE_JWT_SECRET_KEY"].presence ||
               ENV["JWT_SECRET_KEY"].presence ||
               test_key ||
               Rails.application.secret_key_base
      end

      private

      def test_key
        return unless Rails.env.test?

        "test_core_jwt_secret_key_for_local_minitest_only_12345678901234567890"
      end
    end
  end
end
