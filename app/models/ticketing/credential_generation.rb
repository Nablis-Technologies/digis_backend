# frozen_string_literal: true

module Ticketing
  # Immutable version metadata for one mutually exclusive credential set. A
  # package has one active generation; replacing it revokes the old version and
  # creates a new group or delegated set.
  class CredentialGeneration < Ticketing::ApplicationRecord
    self.table_name = "ticketing_credential_generations"

    MODES = %w[group delegated].freeze
    STATUSES = %w[active revoked].freeze

    belongs_to :ticket, class_name: "Ticketing::Ticket"

    has_many :credentials,
             class_name: "Ticketing::Credential",
             dependent: :restrict_with_exception

    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :mode, presence: true, inclusion: { in: MODES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :activated_at, presence: true
    validate :revocation_state_matches

    scope :active, -> { where(status: "active") }
    scope :revoked, -> { where(status: "revoked") }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id ticket_id version mode status activated_at revoked_at revocation_reason created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket credentials]
    end

    private

    def revocation_state_matches
      if status == "active" && revoked_at.present?
        errors.add(:revoked_at, :invalid)
      elsif status == "revoked" && revoked_at.blank?
        errors.add(:revoked_at, :blank)
      end
    end
  end
end
