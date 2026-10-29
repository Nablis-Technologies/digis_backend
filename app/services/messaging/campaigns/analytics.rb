# frozen_string_literal: true

module Messaging
  module Campaigns
    # Returns aggregate campaign delivery and short-link click metrics only.
    class Analytics < Core::BaseService
      def initialize(campaign:)
        @campaign = campaign
      end

      def call
        delivery_counts = CampaignDelivery.where(campaign_id: @campaign.id).group(:status).count
        allocation_sums = CampaignCreditAllocation.where(campaign_id: @campaign.id).group(:status).sum(:quantity)
        clicks = ::Links::ShortLinkClick.where(
          short_link_id: CampaignLink.where(campaign_id: @campaign.id).select(:short_link_id)
        ).count
        success(
          sent: delivery_counts.fetch("sent", 0),
          delivered: delivery_counts.fetch("delivered", 0),
          failed: delivery_counts.fetch("failed", 0),
          suppressed: delivery_counts.fetch("suppressed", 0),
          unavailable: delivery_counts.fetch("unavailable", 0),
          consumed: allocation_sums.fetch("consumed", 0),
          refunded: allocation_sums.fetch("refunded", 0),
          released: allocation_sums.fetch("released", 0),
          clicks:
        )
      end
    end
  end
end
