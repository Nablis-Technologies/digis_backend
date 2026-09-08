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
      return failure(throttled_error) unless allowed?(scope: "ip", value: @ip_address)
      return failure(throttled_error) if @identifier && !allowed?(scope: "identifier", value: @identifier)

      success(true)
    end

    private

    def allowed?(scope:, value:)
      return true if value.blank?

      seeded = @cache.write(cache_key(scope:, value:), 1, expires_in: WINDOW, unless_exist: true)
      return true if seeded

      count = @cache.increment(cache_key(scope:, value:), 1, expires_in: WINDOW)
      count.nil? || count <= LIMIT
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
