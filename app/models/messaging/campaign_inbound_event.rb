# frozen_string_literal: true

module Messaging
  # Provider event identity used to deduplicate inbound opt-out webhooks.
  class CampaignInboundEvent < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_inbound_events"

    STATUSES = %w[received processed ignored failed].freeze

    before_validation :normalize_fields

    validates :provider, :external_event_id, :payload_digest, :status, :received_at,
      presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id provider external_event_id payload_digest status received_at processed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end

    private

    def normalize_fields
      self.provider = provider.to_s.strip.downcase.presence
      self.external_event_id = external_event_id.to_s.strip.presence
      self.payload_digest = payload_digest.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
    end
  end
end
