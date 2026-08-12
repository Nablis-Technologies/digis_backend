# frozen_string_literal: true

module Ticketing
  # One-time recipient acceptance for an individual credential. A claim binds
  # a slot to a recipient without changing the package's commercial owner.
  class CredentialClaim < Ticketing::ApplicationRecord
    self.table_name = "ticketing_credential_claims"

    STATUSES = %w[pending accepted revoked expired].freeze

    belongs_to :credential, class_name: "Ticketing::Credential"
    belongs_to :invited_user, class_name: "Core::User", optional: true
    belongs_to :claimed_by_user, class_name: "Core::User", optional: true

    validates :contact_digest, :token_digest,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validate :acceptance_state_matches

    def self.ransackable_attributes(_auth_object = nil)
      %w[id credential_id invited_user_id claimed_by_user_id contact_digest token_digest status
         expires_at accepted_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[credential invited_user claimed_by_user]
    end

    private

    def acceptance_state_matches
      return unless status == "accepted"

      errors.add(:claimed_by_user, :blank) if claimed_by_user_id.blank?
      errors.add(:accepted_at, :blank) if accepted_at.blank?
    end
  end
end
