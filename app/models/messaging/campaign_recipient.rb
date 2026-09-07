# frozen_string_literal: true

module Messaging
  # One deduplicated channel address in a launch-time campaign snapshot.
  class CampaignRecipient < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_recipients"

    CHANNELS = Messaging::Campaign::CHANNELS
    ELIGIBILITY_STATUSES = %w[eligible suppressed invalid missing_channel].freeze

    belongs_to :campaign, class_name: "Messaging::Campaign", inverse_of: :recipients
    belongs_to :audience_snapshot,
               class_name: "Messaging::CampaignAudienceSnapshot",
               inverse_of: :recipients
    has_one :delivery,
            class_name: "Messaging::CampaignDelivery",
            inverse_of: :campaign_recipient,
            dependent: :destroy
    has_one :credit_allocation, through: :delivery

    encrypts :channel_address_ciphertext, :first_name_ciphertext, :last_name_ciphertext

    def channel_address = channel_address_ciphertext

    def channel_address=(value)
      self.channel_address_ciphertext = value.to_s.strip.presence
    end

    def first_name = first_name_ciphertext

    def first_name=(value)
      self.first_name_ciphertext = value.to_s.strip.presence
    end

    def last_name = last_name_ciphertext

    def last_name=(value)
      self.last_name_ciphertext = value.to_s.strip.presence
    end

    before_validation :normalize_fields

    validates :campaign, :audience_snapshot, :channel, :channel_address_digest,
      :source_type, :eligibility_status, :quantity,
      presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :eligibility_status, inclusion: { in: ELIGIBILITY_STATUSES }
    validates :channel_address_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_id audience_snapshot_id channel channel_address_digest source_type source_id
         historical_basis eligibility_status eligibility_reason quantity created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign audience_snapshot delivery credit_allocation]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.channel_address_digest = channel_address_digest.to_s.strip.downcase.presence
      self.source_type = source_type.to_s.strip.presence
      self.eligibility_status = eligibility_status.to_s.strip.downcase.presence
    end
  end
end
