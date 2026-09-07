# frozen_string_literal: true

module Messaging
  # Retry/reconciliation boundary for one campaign recipient delivery.
  class CampaignDelivery < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_deliveries"

    CHANNELS = Messaging::Campaign::CHANNELS
    STATUSES = %w[pending processing sent delivered failed suppressed unavailable].freeze

    belongs_to :campaign, class_name: "Messaging::Campaign", inverse_of: :deliveries
    belongs_to :campaign_recipient,
               class_name: "Messaging::CampaignRecipient",
               inverse_of: :delivery
    has_one :credit_allocation,
            class_name: "Messaging::CampaignCreditAllocation",
            foreign_key: :delivery_id,
            inverse_of: :delivery,
            dependent: :restrict_with_exception

    before_validation :normalize_fields

    validates :campaign, :campaign_recipient, :channel, :status,
      :idempotency_key_digest, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :idempotency_key_digest, format: { with: /\A[0-9a-f]{64}\z/ }

    def terminal? = status.in?(%w[sent delivered failed suppressed unavailable])

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_id campaign_recipient_id channel status provider attempts next_attempt_at claimed_at sent_at delivered_at failed_at failure_code created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign campaign_recipient credit_allocation]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
    end
  end
end
