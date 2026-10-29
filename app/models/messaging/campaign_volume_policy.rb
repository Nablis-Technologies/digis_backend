# frozen_string_literal: true

module Messaging
  # Admin-configured per-organization/channel campaign unit quota.
  class CampaignVolumePolicy < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_volume_policies"

    CHANNELS = Messaging::Campaign::CHANNELS

    belongs_to :organization, class_name: "Organizations::Organization", optional: true
    belongs_to :updated_by, class_name: "Core::User", optional: true

    before_validation :normalize_fields

    validates :channel, :timezone, :daily_limit, :monthly_limit,
      :idempotency_key_digest, :request_digest, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :daily_limit, :monthly_limit,
      numericality: { only_integer: true, greater_than: 0 }
    validate :timezone_is_valid
    validate :monthly_limit_covers_daily

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id channel timezone daily_limit monthly_limit active created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization updated_by]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.timezone = timezone.to_s.strip.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.request_digest = request_digest.to_s.strip.downcase.presence
    end

    def timezone_is_valid
      return if timezone.blank? || ActiveSupport::TimeZone[timezone].present?

      errors.add(:timezone, :invalid)
    end

    def monthly_limit_covers_daily
      return if daily_limit.blank? || monthly_limit.blank? || monthly_limit >= daily_limit

      errors.add(:monthly_limit, :invalid)
    end
  end
end
