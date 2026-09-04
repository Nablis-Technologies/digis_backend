# frozen_string_literal: true

module Messaging
  # Stable organization/channel aggregate used for ownership and credit locks.
  # Available balance is derived from immutable ledger evidence.
  class CreditAccount < Messaging::ApplicationRecord
    self.table_name = "messaging_credit_accounts"

    CHANNELS = %w[sms email].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    has_many :ledger_entries,
             class_name: "Messaging::CreditLedgerEntry",
             foreign_key: :credit_account_id,
             inverse_of: :credit_account,
             dependent: :restrict_with_exception
    has_many :reservations,
             class_name: "Messaging::CreditReservation",
             foreign_key: :credit_account_id,
             inverse_of: :credit_account,
             dependent: :restrict_with_exception
    has_many :top_ups,
             class_name: "Messaging::CreditTopUp",
             foreign_key: :credit_account_id,
             inverse_of: :credit_account,
             dependent: :restrict_with_exception

    before_validation :normalize_fields

    validates :organization, :channel, presence: true
    validates :channel, inclusion: { in: CHANNELS }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id channel created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization ledger_entries reservations top_ups]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
    end
  end
end
