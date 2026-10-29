# frozen_string_literal: true

module Messaging
  # Reusable organization or platform template definition.
  class CampaignTemplate < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_templates"

    CHANNELS = Messaging::Campaign::CHANNELS
    STATUSES = %w[draft active retired].freeze

    belongs_to :organization, class_name: "Organizations::Organization", optional: true
    belongs_to :created_by, class_name: "Core::User", optional: true
    has_many :versions,
             class_name: "Messaging::CampaignTemplateVersion",
             foreign_key: :campaign_template_id,
             inverse_of: :campaign_template,
             dependent: :restrict_with_exception

    before_validation :normalize_fields

    validates :name, :channel, :status, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validate :metadata_is_object

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id created_by_id name channel status created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization created_by versions]
    end

    private

    def normalize_fields
      self.name = name.to_s.strip.presence
      self.channel = channel.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.metadata = {} if metadata.nil?
    end

    def metadata_is_object
      errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
    end
  end
end
