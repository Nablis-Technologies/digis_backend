# frozen_string_literal: true

module Messaging
  # Starts at most 100 due campaigns and hands each to bounded fan-out.
  class ProcessScheduledCampaignsJob < ApplicationJob
    BATCH_SIZE = 100

    queue_as :notifications

    def perform
      now = Time.current
      Campaign.transaction do
        Campaign.where(status: "scheduled").where("send_at <= ?", now).order(:id)
          .limit(BATCH_SIZE).lock("FOR UPDATE SKIP LOCKED").to_a.each do |campaign|
          campaign.update!(status: "sending")
          FanoutCampaignJob.perform_later(campaign.id)
        end
      end
    end
  end
end
