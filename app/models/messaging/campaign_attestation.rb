# frozen_string_literal: true

module Messaging
  # Append-only organizer assertion that a selected audience may be contacted.
  class CampaignAttestation < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_attestations"

    CHANNELS = Messaging::Campaign::CHANNELS

    belongs_to :campaign, class_name: "Messaging::Campaign", inverse_of: :attestations
    belongs_to :audience_snapshot,
               class_name: "Messaging::CampaignAudienceSnapshot", inverse_of: :attestations
    belongs_to :actor, class_name: "Core::User"

    before_validation :normalize_fields

    validates :campaign, :audience_snapshot, :actor, :channel, :statement_version,
      :idempotency_key_digest, :request_digest, :attested_at, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :statement_version, numericality: { only_integer: true, greater_than: 0 }
    validates :idempotency_key_digest, :request_digest,
      format: { with: /\A[0-9a-f]{64}\z/ }
    validate :metadata_is_object

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_id audience_snapshot_id actor_id channel historical_basis statement_version attested_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign audience_snapshot actor]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.historical_basis = historical_basis.to_s.strip.presence
      self.metadata = {} if metadata.nil?
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.request_digest = request_digest.to_s.strip.downcase.presence
    end

    def metadata_is_object
      errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
    end
  end
end
