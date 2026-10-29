# frozen_string_literal: true

module Messaging
  # Immutable localized content version used by a campaign snapshot.
  class CampaignTemplateVersion < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_template_versions"

    STATUSES = %w[draft active retired].freeze
    VARIABLES = %w[event_name event_date venue_name ticket_link first_name organization_name].freeze

    belongs_to :campaign_template,
               class_name: "Messaging::CampaignTemplate",
               inverse_of: :versions
    belongs_to :created_by, class_name: "Core::User", optional: true
    has_many :campaigns,
             class_name: "Messaging::Campaign",
             foreign_key: :campaign_template_version_id,
             inverse_of: :campaign_template_version,
             dependent: :restrict_with_exception

    encrypts :subject_ciphertext, :body_ciphertext

    def subject = subject_ciphertext

    def subject=(value)
      self.subject_ciphertext = value.to_s.presence
    end

    def body = body_ciphertext

    def body=(value)
      self.body_ciphertext = value.to_s
    end

    before_validation :normalize_fields

    validates :campaign_template, :version, :locale, :body, :status, presence: true
    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :status, inclusion: { in: STATUSES }
    validate :variables_are_allowed
    validate :variables_are_array
    validate :declared_variables_match_content

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_template_id created_by_id version locale status created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign_template created_by campaigns]
    end

    private

    def normalize_fields
      self.locale = locale.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.variables = Array(variables).map { |variable| variable.to_s.strip }.reject(&:blank?).uniq
    end

    def variables_are_array
      errors.add(:variables, :invalid) unless variables.is_a?(Array)
    end

    def variables_are_allowed
      return unless variables.is_a?(Array)

      unknown = variables.map(&:to_s) - VARIABLES
      errors.add(:body, :unknown_variable) if unknown.any?
    end

    def declared_variables_match_content
      return unless variables.is_a?(Array)

      used = Messaging::Campaigns::Templates::Variables.extract(body) +
        Messaging::Campaigns::Templates::Variables.extract(subject)
      errors.add(:variables, :undeclared_variable) if (used - variables).any?
    end
  end
end
