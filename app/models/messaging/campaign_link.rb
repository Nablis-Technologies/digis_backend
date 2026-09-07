# frozen_string_literal: true

module Messaging
  # Campaign-owned reference to an existing branded short link.
  class CampaignLink < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_links"

    CHANNELS = Messaging::Campaign::CHANNELS

    belongs_to :campaign, class_name: "Messaging::Campaign", inverse_of: :campaign_links
    belongs_to :short_link, class_name: "Links::ShortLink"

    before_validation :normalize_fields

    validates :campaign, :short_link, :channel, :name, presence: true
    validates :channel, inclusion: { in: CHANNELS }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_id short_link_id channel name created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign short_link]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.name = name.to_s.strip.presence
    end
  end
end
