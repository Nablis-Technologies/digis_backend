# frozen_string_literal: true

module Messaging
  module Campaigns
    # Restarts delivery for a paused campaign through bounded fan-out jobs.
    class Resume < Core::BaseService
      include LifecycleCommandSupport

      def initialize(campaign:, actor:, idempotency_key:)
        @campaign = campaign
        @actor = actor
        @raw_idempotency_key = idempotency_key
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?
        request_digest = lifecycle_request_digest(action: "resumed", key:)
        audit_key = lifecycle_audit_key(action: "resumed", key:)

        ActiveRecord::Base.transaction do
          campaign = Campaign.lock.find(@campaign.id)
          replay = lifecycle_replay(audit_key:, request_digest:, campaign:)
          return replay if replay
          return success(campaign) if campaign.status == "sending"
          return failure(error(:campaign_invalid_state, status: :conflict)) unless campaign.status == "paused"

          previous_status = campaign.status
          campaign.update!(status: "sending")
          FanoutCampaignJob.perform_later(campaign.id)
          record_lifecycle_audit!(action: "messaging.campaign.resumed", audit_key:, request_digest:, key:, campaign:,
            from: previous_status, to: "sending")
          success(campaign)
        end
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:campaign_invalid_state, message: exception.message))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def authorized?
        Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)
      end

      def error(key, message: nil, status: :unprocessable_entity)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
