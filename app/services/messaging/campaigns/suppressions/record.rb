# frozen_string_literal: true

module Messaging
  module Campaigns
    module Suppressions
      # Appends one global or organization-scoped channel suppression.
      class Record < Core::BaseService
        def initialize(organization: nil, channel:, channel_address_digest:, source:, reason:, idempotency_key:)
          @organization = organization
          @channel = channel.to_s.strip.downcase
          @digest = channel_address_digest.to_s.strip.downcase
          @source = source.to_s.strip
          @reason = reason.to_s.strip
          @key = Core::IdempotencyKey.new(idempotency_key)
        end

        def call
          return failure(error(:campaign_audience_invalid)) unless Campaign::CHANNELS.include?(@channel)
          return failure(error(:campaign_contact_required)) unless @digest.match?(/\A[0-9a-f]{64}\z/)
          return failure(error(:campaign_audience_invalid)) if @source.blank? || @reason.blank?

          existing = CampaignSuppression.find_by(idempotency_key_digest: @key.digest)
          return replay(existing) if existing

          existing_scope = CampaignSuppression.find_by(
            organization_id: @organization&.id,
            channel: @channel,
            channel_address_digest: @digest
          )
          return success(existing_scope) if existing_scope

          suppression = CampaignSuppression.create!(
            organization: @organization,
            channel: @channel,
            channel_address_digest: @digest,
            source: @source,
            reason: @reason,
            suppressed_at: Time.current,
            idempotency_key_digest: @key.digest
          )
          success(suppression)
        rescue ActiveRecord::RecordNotUnique
          existing = CampaignSuppression.find_by(idempotency_key_digest: @key.digest)
          return replay(existing) if existing

          success(CampaignSuppression.find_by!(
            organization_id: @organization&.id,
            channel: @channel,
            channel_address_digest: @digest
          ))
        rescue ArgumentError => exception
          failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:campaign_audience_invalid, message: exception.message))
        end

        private

        def replay(existing)
          return failure(error(:idempotency_conflict, status: :conflict)) unless matches?(existing)

          success(existing)
        end

        def matches?(existing)
          existing.organization_id == @organization&.id && existing.channel == @channel &&
            existing.channel_address_digest == @digest && existing.source == @source && existing.reason == @reason
        end

        def error(key, message: nil, status: :unprocessable_entity)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
        end
      end
    end
  end
end
