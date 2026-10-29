# frozen_string_literal: true

module Finance
  # A payout is the durable intent to transfer one positive, same-currency
  # organizer net balance. Its allocations reserve immutable ledger facts;
  # provider state is reconciled separately from the accounting transaction.
  class Payout < Finance::ApplicationRecord
    self.table_name = "finance_payouts"

    include Core::AuditableModel

    STATUSES = %w[pending processing paid failed cancelled].freeze

    belongs_to :organization, class_name: "Organizations::Organization",
               inverse_of: :finance_payouts
    belongs_to :payout_account, class_name: "Finance::PayoutAccount",
               inverse_of: :payouts
    has_many :allocations,
             class_name: "Finance::PayoutAllocation",
             foreign_key: :payout_id,
             dependent: :restrict_with_exception,
             inverse_of: :payout

    validates :organization, :payout_account, :currency, :status, :amount_minor, :idempotency_key, :requested_at,
              presence: true
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :status, inclusion: { in: STATUSES }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :idempotency_key, uniqueness: true
    validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :paid_at_requires_paid
    validate :provider_reference_requires_provider

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id payout_account_id currency status amount_minor provider provider_reference idempotency_key
         period_start period_end requested_at paid_at failure_code created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization payout_account allocations]
    end

    def pending? = status == "pending"

    def processing? = status == "processing"

    def paid? = status == "paid"

    private

    def paid_at_requires_paid
      return if paid_at.blank? || status == "paid"

      errors.add(:paid_at, :invalid)
    end

    def provider_reference_requires_provider
      return if provider_reference.blank? || provider.present?

      errors.add(:provider, :blank)
    end
  end
end
