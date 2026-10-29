# frozen_string_literal: true

module Messaging
  # Append-only credit evidence. Corrections are new entries, never updates.
  class CreditLedgerEntry < Messaging::ApplicationRecord
    self.table_name = "messaging_credit_ledger_entries"

    ENTRY_TYPES = %w[top_up reserve consume release refund expire adjustment].freeze
    REFERENCE_TYPES = %w[
      Orders::BillingPurchase
      Messaging::CreditReservation
      Messaging::CreditTopUp
      Messaging::CreditAdjustment
      Messaging::Campaign
      Messaging::CampaignDelivery
    ].freeze

    belongs_to :credit_account,
               class_name: "Messaging::CreditAccount",
               inverse_of: :ledger_entries
    belongs_to :rate_version,
               class_name: "Messaging::CreditRateVersion",
               optional: true,
               inverse_of: :ledger_entries

    before_validation :normalize_fields
    before_update :prevent_mutation
    before_destroy :prevent_mutation

    validates :credit_account, :entry_type, :quantity, :available_delta,
      :idempotency_key_digest, presence: true
    validates :entry_type, inclusion: { in: ENTRY_TYPES }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :idempotency_key_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :reference_type, inclusion: { in: REFERENCE_TYPES }, allow_nil: true
    validate :metadata_is_object

    def self.ransackable_attributes(_auth_object = nil)
      %w[id credit_account_id rate_version_id entry_type quantity available_delta reference_type reference_id
         idempotency_key_digest created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[credit_account rate_version]
    end

    private

    def normalize_fields
      self.entry_type = entry_type.to_s.strip.downcase.presence
      self.reference_type = reference_type.to_s.strip.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.metadata = {} if metadata.nil?
    end

    def metadata_is_object
      errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
    end

    def prevent_mutation
      raise ActiveRecord::ReadOnlyRecord, I18n.t("messaging.errors.credit_ledger_immutable")
    end
  end
end
