# frozen_string_literal: true

module Ticketing
  # Event-scoped package revocation projection consumed by offline scanners.
  # Versions advance monotonically while the package row and its credential
  # history remain available for audit and reconciliation.
  class Revocation < Ticketing::ApplicationRecord
    self.table_name = "ticketing_revocations"

    belongs_to :event, class_name: "Events::Event"
    belongs_to :ticket, class_name: "Ticketing::Ticket"

    validates :revoked_through_version, :revocation_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id ticket_id revoked_through_version is_dead is_suspended revocation_version
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event ticket]
    end
  end
end
