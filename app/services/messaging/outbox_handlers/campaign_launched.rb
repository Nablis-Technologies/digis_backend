# frozen_string_literal: true

module Messaging
  module OutboxHandlers
    # Hands an accepted launch to immediate or scheduled bounded fan-out.
    class CampaignLaunched < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        campaign = Campaign.find(@event.payload.fetch("campaign_id"))
        return success(@event) if campaign.status.in?(%w[paused canceled completed failed])

        dispatch_at = @event.payload["dispatch_at"]
        if dispatch_at.blank? || Time.iso8601(dispatch_at) <= Time.current
          FanoutCampaignJob.perform_later(campaign.id)
        end
        success(@event)
      rescue ArgumentError, KeyError, ActiveRecord::RecordNotFound => exception
        failure(Core::BusinessError.new(exception.message, code: "campaign_launch_invalid", status: :unprocessable_entity))
      end
    end
  end
end
