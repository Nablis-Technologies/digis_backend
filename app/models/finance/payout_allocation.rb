# frozen_string_literal: true

module Finance
  # Reserves a signed slice of one immutable ledger fact for one payout. The
  # database trigger enforces ownership, currency, sign, and remaining amount;
  # the command layer enforces negative-first settlement ordering.
  class PayoutAllocation < Finance::ApplicationRecord
    self.table_name = "finance_payout_allocations"

    STATUSES = %w[reserved consumed released].freeze

    belongs_to :payout, class_name: "Finance::Payout", inverse_of: :allocations
    belongs_to :ledger_entry, class_name: "Finance::LedgerEntry", inverse_of: :payout_allocations

    validates :payout, :ledger_entry, :amount_minor, :status, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :amount_minor, numericality: { only_integer: true, other_than: 0 }
    validate :amount_sign_matches_ledger

    def self.ransackable_attributes(_auth_object = nil)
      %w[id payout_id ledger_entry_id amount_minor status consumed_at released_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[payout ledger_entry]
    end

    def reserved? = status == "reserved"

    def consumed? = status == "consumed"

    def released? = status == "released"

    private

    def amount_sign_matches_ledger
      return if amount_minor.blank? || ledger_entry.blank?
      return if amount_minor.positive? == ledger_entry.amount_minor.positive?

      errors.add(:amount_minor, :invalid)
    end
  end
end
