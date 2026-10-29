# frozen_string_literal: true

module Messaging
  # Immutable-at-ready audience materialization used by quotes and dispatch.
  class CampaignAudienceSnapshot < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_audience_snapshots"

    STATUSES = %w[preparing ready failed].freeze

    belongs_to :campaign,
               class_name: "Messaging::Campaign",
               inverse_of: :audience_snapshot
    has_many :recipients,
             class_name: "Messaging::CampaignRecipient",
             foreign_key: :audience_snapshot_id,
             inverse_of: :audience_snapshot,
             dependent: :destroy
    has_many :attestations,
             class_name: "Messaging::CampaignAttestation",
             foreign_key: :audience_snapshot_id,
             inverse_of: :audience_snapshot,
             dependent: :destroy

    before_validation :normalize_fields

    validates :campaign, :status, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate :source_spec_is_object
    validates :processed_count, :total_count, :eligible_quantity,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_id status processed_count total_count eligible_quantity started_at completed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign recipients]
    end

    private

    def normalize_fields
      self.status = status.to_s.strip.downcase.presence
      self.source_spec = {} if source_spec.nil?
    end

    def source_spec_is_object
      errors.add(:source_spec, :invalid) unless source_spec.is_a?(Hash)
    end
  end
end
