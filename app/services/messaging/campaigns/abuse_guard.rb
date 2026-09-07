# frozen_string_literal: true

module Messaging
  module Campaigns
    # Cache-backed request limiter for unauthenticated campaign ingress.
    class AbuseGuard < Core::BaseService
      WINDOW = 1.minute

      def initialize(scope:, identity:, limit:)
        @scope = scope.to_s.strip
        @identity = identity.to_s.strip
        @limit = Integer(limit)
      end

      def call
        return failure(error(:campaign_audience_invalid)) if @scope.blank? || @identity.blank? || @limit <= 0

        count = Rails.cache.increment(cache_key, 1, expires_in: WINDOW)
        Rails.cache.write(cache_key, 1, expires_in: WINDOW) if count.nil?
        return failure(error(:rate_limited, status: :too_many_requests)) if count && count > @limit

        success(true)
      rescue ArgumentError
        failure(error(:campaign_audience_invalid))
      end

      private

      def cache_key
        digest = Core::KeyedDigest.digest(namespace: "messaging-campaign-abuse", value: "#{@scope}:#{@identity}")
        "messaging-campaign-abuse:#{digest}"
      end

      def error(key, status: :unprocessable_entity)
        Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
