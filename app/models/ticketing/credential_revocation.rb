# frozen_string_literal: true

module Ticketing
  # Credential-level revocation projection for delegated-slot replacement.
  # It invalidates one credential UUID without invalidating unrelated slots in
  # the same delegated generation.
  class CredentialRevocation < Ticketing::ApplicationRecord
    self.table_name = "ticketing_credential_revocations"

    belongs_to :event, class_name: "Events::Event", inverse_of: :credential_revocations
    belongs_to :credential, class_name: "Ticketing::Credential"

    validates :reason, presence: true
    validates :revoked_at, presence: true
    validates :revocation_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id credential_id reason revoked_at revocation_version created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event credential]
    end
  end
end
