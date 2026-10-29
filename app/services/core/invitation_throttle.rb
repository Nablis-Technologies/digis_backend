# frozen_string_literal: true

module Core
  # Limits staff-invitation operations independently by actor, contact, and
  # source IP. Cache keys contain keyed digests rather than raw identifiers.
  class InvitationThrottle < Core::BaseService
    LIMIT = Core::AuthThrottle::LIMIT
    WINDOW = Core::AuthThrottle::WINDOW

    def initialize(actor_id:, contact_digest: nil, token_digest: nil, ip_address:, cache: Rails.cache)
      @actor_id = actor_id.to_s
      @contact_digest = contact_digest.to_s.presence || token_digest.to_s.presence
      @ip_address = ip_address.to_s
      @cache = cache
    end

    def call
      counts = scopes.filter_map { |scope, value| increment(scope:, value:) }
      return failure(rate_limited_error) if counts.any? { |count| count > LIMIT }

      success(true)
    end

    private

    attr_reader :actor_id, :contact_digest, :ip_address, :cache

    def scopes
      [ [ "actor", actor_id ], [ "contact", contact_digest ], [ "ip", ip_address ] ]
    end

    def increment(scope:, value:)
      return if value.blank?

      key = cache_key(scope:, value:)
      seeded = cache.write(key, 1, expires_in: WINDOW, unless_exist: true)
      return 1 if seeded

      cache.increment(key, 1, expires_in: WINDOW)
    end

    def cache_key(scope:, value:)
      digest = Core::KeyedDigest.digest(namespace: "core/invitation-throttle/#{scope}", value:)
      "core-invitation-throttle:#{digest}"
    end

    def rate_limited_error
      Core::BusinessError.new(
        I18n.t("auth.errors.rate_limited"),
        code: "rate_limited",
        status: :too_many_requests
      )
    end
  end
end
