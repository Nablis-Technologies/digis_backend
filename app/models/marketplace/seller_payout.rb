# frozen_string_literal: true

module Marketplace
  # Provider payout intent for one seller. Allocation rows reserve positive
  # ledger facts before a provider dispatch; provider callbacks only advance
  # this lifecycle and never rewrite the payout amount or currency.
  class SellerPayout < Marketplace::ApplicationRecord
    self.table_name = "marketplace_seller_payouts"
    self.inheritance_column = nil

    STATUSES = %w[pending processing succeeded failed cancelled].freeze
    PROVIDERS = SellerPayoutAccount::PROVIDERS

    belongs_to :seller_user, class_name: "Core::User"
    belongs_to :seller_payout_account, class_name: "Marketplace::SellerPayoutAccount"
    has_many :seller_payout_allocations,
             class_name: "Marketplace::SellerPayoutAllocation",
             dependent: :restrict_with_exception,
             inverse_of: :payout
    has_many :seller_ledger_entries,
             class_name: "Marketplace::SellerLedgerEntry",
             dependent: :restrict_with_exception

    before_validation :normalize_fields

    validates :seller_user, :seller_payout_account, :provider, :amount_minor, :currency, :status,
              :idempotency_key, :requested_at, presence: true
    validates :provider, inclusion: { in: PROVIDERS }
    validates :status, inclusion: { in: STATUSES }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :idempotency_key, uniqueness: true

    validate :verified_account_scope
    validate :lifecycle_metadata

    def pending? = status == "pending"

    def processing? = status == "processing"

    def succeeded? = status == "succeeded"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id seller_user_id seller_payout_account_id provider provider_reference amount_minor currency status
         idempotency_key requested_at processed_at failure_code lock_version created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[seller_user seller_payout_account seller_payout_allocations seller_ledger_entries]
    end

    private

    def normalize_fields
      self.provider = provider.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.provider_reference = provider_reference.to_s.strip.presence
      self.failure_code = failure_code.to_s.strip.presence
    end

    def verified_account_scope
      return if seller_payout_account.blank? || seller_user.blank?

      errors.add(:seller_payout_account, :invalid) unless seller_payout_account.verified?
      errors.add(:seller_user, :invalid) unless seller_payout_account.user_id == seller_user_id
    end

    def lifecycle_metadata
      terminal = status.in?(%w[succeeded failed cancelled])
      if terminal
        errors.add(:processed_at, :blank) if processed_at.blank?
      elsif processed_at.present?
        errors.add(:processed_at, :invalid)
      end

      if status == "failed"
        errors.add(:failure_code, :blank) if failure_code.blank?
      elsif failure_code.present?
        errors.add(:failure_code, :invalid)
      end
    end
  end
end
