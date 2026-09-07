# frozen_string_literal: true

module Messaging
  module Campaigns
    # Pins a ready audience's quantity and rate for a short launch quote.
    class Estimate < Core::BaseService
      TTL = 15.minutes

      def initialize(campaign:, actor:, idempotency_key:)
        @campaign = campaign
        @actor = actor
        @key = Core::IdempotencyKey.new(idempotency_key)
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?

        snapshot = @campaign.audience_snapshot
        if snapshot.nil?
          snapshot_result = Audience::Snapshot.call(
            campaign: @campaign, actor: @actor, idempotency_key: "estimate-snapshot-#{@key}"
          )
          return failure(snapshot_result.error) if snapshot_result.failure?

          snapshot = snapshot_result.value
        end
        return success(progress(snapshot)) if snapshot.status == "preparing"
        return failure(error(:campaign_audience_snapshot_invalid)) unless snapshot.status == "ready"

        if @campaign.metadata.to_h["estimate_idempotency_key_digest"] == @key.digest &&
          @campaign.quoted_quantity.present?
          return failure(error(:campaign_quote_stale, status: :conflict)) if quote_expired?

          return success(
            status: "ready", quantity: @campaign.quoted_quantity,
            rate_version: @campaign.quoted_rate_version,
            unit_price_minor: @campaign.quoted_unit_price_minor,
            quote_digest: @campaign.quote_digest, quoted_at: @campaign.quoted_at,
            quote_expires_at: @campaign.quote_expires_at
          )
        end

        quantity = snapshot.recipients.where(eligibility_status: "eligible").sum(:quantity)
        return failure(error(:campaign_audience_empty)) if quantity <= 0

        quota = Quota.call(
          organization: @campaign.organization, channel: @campaign.channel, quantity:,
          timezone: @campaign.timezone
        )
        return failure(quota.error) if quota.failure?
        rate = ResolveCreditRate.call(
          organization: @campaign.organization, channel: @campaign.channel, quantity:,
          currency: @campaign.metadata.to_h["currency"] || "ETB",
          country_code: @campaign.metadata.to_h["country_code"]
        )
        return failure(rate.error) if rate.failure?

        persist_quote(rate.value, quantity)
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:campaign_quote_incomplete, message: exception.message))
      end

      private

      def authorized?
        Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)
      end

      def progress(snapshot)
        {
          status: "preparing",
          snapshot_id: snapshot&.id,
          processed_count: snapshot&.processed_count.to_i,
          total_count: snapshot&.total_count.to_i
        }
      end

      def persist_quote(selected, quantity)
        quoted_at = Time.current
        rate = selected.fetch(:rate_version)
        quote_digest = Core::KeyedDigest.digest(
          namespace: "messaging-campaign-quote",
          value: "#{@campaign.id}:#{rate.id}:#{quantity}:#{quoted_at.to_i}"
        )
        @campaign.update!(
          quoted_rate_version: rate, quoted_quantity: quantity, quoted_unit_price_minor: selected[:unit_price_minor], quote_digest:, quoted_at:,
          quote_expires_at: quoted_at + TTL,
          metadata: @campaign.metadata.merge("estimate_idempotency_key_digest" => @key.digest)
        )
        success(status: "ready", quantity:, rate_version: rate, unit_price_minor: selected[:unit_price_minor],
          quote_digest:, quoted_at:, quote_expires_at: @campaign.quote_expires_at)
      end

      def quote_expired?
        @campaign.quote_expires_at.blank? || @campaign.quote_expires_at <= Time.current
      end

      def error(key, message: nil, status: :unprocessable_entity)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
