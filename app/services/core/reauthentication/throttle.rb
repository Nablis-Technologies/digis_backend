# frozen_string_literal: true

module Core
  module Reauthentication
    # Applies bounded password-failure and issuance-attempt limits without
    # exposing user, session, IP, or purpose values in cache keys.
    class Throttle < Core::BaseService
      USER_FAILURE_LIMIT = 5
      USER_FAILURE_WINDOW = 15.minutes
      IP_ATTEMPT_LIMIT = 30
      IP_ATTEMPT_WINDOW = 1.hour

      def initialize(user:, session_jti:, purpose:, ip_address: nil, failed_password: false)
        @user = user
        @session_jti = session_jti
        @purpose = purpose
        @ip_address = ip_address
        @failed_password = failed_password
      end

      def call
        count = increment_counter
        return failure(throttled_error) if count > limit

        success
      end

      private

      def increment_counter
        count = Rails.cache.increment(cache_key, 1, expires_in: window)
        return count if count

        Rails.cache.write(cache_key, 1, expires_in: window)
        1
      end

      def cache_key
        value = @failed_password ? "#{@user&.id}:#{@session_jti}" : @ip_address
        digest = Core::KeyedDigest.digest(
          namespace: "core/reauthentication/throttle/#{counter_name}/#{@purpose}",
          value: value
        )
        "core/reauthentication/#{digest}"
      end

      def counter_name
        @failed_password ? "password_failure" : "issuance_attempt"
      end

      def limit
        @failed_password ? USER_FAILURE_LIMIT : IP_ATTEMPT_LIMIT
      end

      def window
        @failed_password ? USER_FAILURE_WINDOW : IP_ATTEMPT_WINDOW
      end

      def throttled_error
        Core::BusinessError.new(
          I18n.t("reauthentication.errors.throttled"),
          code: I18n.t("reauthentication.codes.throttled"),
          status: 429
        )
      end
    end
  end
end
