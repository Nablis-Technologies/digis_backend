# frozen_string_literal: true

module Messaging
  # Organization-owned marketing campaign with an immutable channel boundary.
  class Campaign < Messaging::ApplicationRecord
    self.table_name = "messaging_campaigns"

    CHANNELS = %w[sms email].freeze
    STATUSES = %w[draft scheduled sending paused canceled completed failed].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :created_by, class_name: "Core::User"
    belongs_to :event, class_name: "Events::Event", optional: true
    belongs_to :campaign_template_version,
               class_name: "Messaging::CampaignTemplateVersion",
               optional: true
    belongs_to :quoted_rate_version,
               class_name: "Messaging::CreditRateVersion",
               optional: true
    encrypts :message_subject_ciphertext, :message_body_ciphertext
    has_one :audience_snapshot,
            class_name: "Messaging::CampaignAudienceSnapshot",
            inverse_of: :campaign,
            dependent: :destroy
    has_many :recipients,
             class_name: "Messaging::CampaignRecipient",
             inverse_of: :campaign,
             dependent: :destroy
    has_many :deliveries,
             class_name: "Messaging::CampaignDelivery",
             inverse_of: :campaign,
             dependent: :destroy
    has_many :attestations,
             class_name: "Messaging::CampaignAttestation",
             inverse_of: :campaign,
             dependent: :destroy
    has_many :credit_allocations,
             class_name: "Messaging::CampaignCreditAllocation",
             inverse_of: :campaign,
             dependent: :destroy
    has_many :campaign_links,
             class_name: "Messaging::CampaignLink",
             inverse_of: :campaign,
             dependent: :destroy

    before_validation :normalize_fields

    validates :organization, :created_by, :name, :channel, :status, :timezone,
      presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :launch_version, numericality: { only_integer: true, greater_than: 0 }
    validates :quoted_quantity, :quoted_unit_price_minor,
      numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :quote_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
    validate :quote_fields_are_complete
    validate :immutable_fields
    validate :timezone_is_valid
    validate :variables_are_allowlisted

    def message_subject = message_subject_ciphertext

    def message_subject=(value)
      self.message_subject_ciphertext = value.to_s.presence
    end

    def message_body = message_body_ciphertext

    def message_body=(value)
      self.message_body_ciphertext = value.to_s.presence
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id created_by_id event_id campaign_template_version_id name channel status timezone
         launch_version send_at launched_at completed_at canceled_at quoted_quantity quoted_rate_version_id
         quote_digest quoted_at quote_expires_at quoted_unit_price_minor created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization created_by event campaign_template_version quoted_rate_version audience_snapshot recipients deliveries campaign_links]
    end

    private

    def normalize_fields
      self.name = name.to_s.strip.presence
      self.channel = channel.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.timezone = timezone.to_s.strip.presence
      self.variables = variables.stringify_keys if variables.is_a?(Hash)
    end

    def variables_are_allowlisted
      unless variables.is_a?(Hash)
        errors.add(:variables, :invalid)
        return
      end

      unknown = variables.keys.map(&:to_s) - Campaigns::Templates::Variables::ALLOWED
      errors.add(:variables, :invalid) if unknown.any?
    end

    def quote_fields_are_complete
      fields = [ quoted_rate_version_id, quoted_quantity, quoted_unit_price_minor, quote_digest, quoted_at, quote_expires_at ]
      return if fields.all?(&:blank?) || fields.all?(&:present?)

      errors.add(:base, :quote_incomplete)
    end

    def immutable_fields
      return unless persisted?

      errors.add(:channel, :immutable) if will_save_change_to_channel?
      return if status_was == "draft"

      %w[name timezone campaign_template_version_id event_id quoted_rate_version_id quoted_quantity quoted_unit_price_minor
         quote_digest quoted_at quote_expires_at message_subject_ciphertext message_body_ciphertext variables].each do |field|
        errors.add(field, :immutable) if will_save_change_to_attribute?(field)
      end
    end

    def timezone_is_valid
      return if timezone.blank?
      return if ActiveSupport::TimeZone[timezone].present?

      errors.add(:timezone, :invalid)
    end
  end
end
