# frozen_string_literal: true

module Messaging
  # Channel-address suppression; a nil organization is a global opt-out.
  class CampaignSuppression < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_suppressions"

    CHANNELS = Messaging::Campaign::CHANNELS

    belongs_to :organization, class_name: "Organizations::Organization", optional: true

    before_validation :normalize_fields

    validates :channel, :channel_address_digest, :source, :reason,
      :suppressed_at, :idempotency_key_digest, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :channel_address_digest, :idempotency_key_digest,
      format: { with: /\A[0-9a-f]{64}\z/ }
    validates :idempotency_key_digest, uniqueness: true

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id channel channel_address_digest source reason suppressed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.channel_address_digest = channel_address_digest.to_s.strip.downcase.presence
      self.source = source.to_s.strip.presence
      self.reason = reason.to_s.strip.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
    end
  end
end
