# frozen_string_literal: true

module Messaging
  module Campaigns
    module Audience
      # Starts one immutable audience materialization for a campaign.
      class Snapshot < Core::BaseService
        def initialize(campaign:, actor:, idempotency_key:, sources: nil)
          @campaign = campaign
          @actor = actor
          @key = Core::IdempotencyKey.new(idempotency_key)
          @sources = sources || campaign.metadata.to_h["audience_sources"] || []
        end

        def call
          return failure(error(:unauthorized, status: :forbidden)) unless authorized?

          existing = @campaign.audience_snapshot
          return replay(existing) if existing

          snapshot = CampaignAudienceSnapshot.create!(
            campaign: @campaign,
            source_spec: { "sources" => normalized_sources, "idempotency_key_digest" => @key.digest },
            status: "preparing",
            started_at: Time.current
          )
          PrepareCampaignAudienceJob.perform_later(snapshot.id)
          success(snapshot)
        rescue ActiveRecord::RecordNotUnique
          replay(@campaign.audience_snapshot)
        rescue ArgumentError => exception
          failure(error(:campaign_audience_invalid, message: exception.message, status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:campaign_audience_snapshot_invalid, message: exception.message))
        end

        private

        def normalized_sources
          Array(@sources).map { |source| source.to_h.stringify_keys }
        end

        def replay(snapshot)
          return failure(error(:campaign_audience_snapshot_invalid)) unless snapshot

          original_key = snapshot.source_spec.to_h["idempotency_key_digest"]
          return success(snapshot) if original_key.blank? || original_key == @key.digest

          failure(error(:idempotency_conflict, status: :conflict))
        end

        def authorized?
          Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)
        end

        def error(key, message: nil, status: :unprocessable_entity)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
        end
      end
    end
  end
end
