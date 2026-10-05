# frozen_string_literal: true

module Core
  # Applies a small, shared boundary to unauthenticated authentication calls.
  # Cache keys contain only keyed digests, so raw identifiers never enter the
  # cache or logs. The cache store's atomic increment is the concurrency gate.
  class AuthThrottle < Core::BaseService
    LIMIT = 10
    WINDOW = 1.minute

    def initialize(identifier:, ip_address:, cache: Rails.cache)
      @identifier = identifier.to_s.strip.downcase.presence
      @ip_address = ip_address.to_s.strip.presence
      @cache = cache
    end

    def call
      return failure(throttled_error) if throttled?

      success(true)
    end

    def record_failure
      record_attempt
    end

    # Counts a potentially costly auth-side effect, such as sending an OTP,
    # even when the action itself succeeds.
    def record_attempt
      counts = [
        increment(scope: "ip", value: @ip_address),
        increment(scope: "identifier", value: @identifier)
      ]
      return failure(throttled_error) if counts.any? { |count| count && count > LIMIT }

      success(true)
    end

    private

    def throttled?
      [ [ "ip", @ip_address ], [ "identifier", @identifier ] ].any? do |scope, value|
        value.present? && @cache.read(cache_key(scope:, value:)).to_i >= LIMIT
      end
    end

    def increment(scope:, value:)
      return if value.blank?

      key = cache_key(scope:, value:)
      seeded = @cache.write(key, 1, expires_in: WINDOW, unless_exist: true)
      return 1 if seeded

      @cache.increment(key, 1, expires_in: WINDOW)
    end

    def cache_key(scope:, value:)
      digest = Core::KeyedDigest.digest(namespace: "core/auth-throttle/#{scope}", value:)
      "core-auth-throttle:#{digest}"
    end

    def throttled_error
      Core::BusinessError.new(
        I18n.t("auth.errors.rate_limited"), code: "rate_limited", status: :too_many_requests
      )
    end
  end
end
