# frozen_string_literal: true

module Marketplace
  # Reserves the absolute value of one signed seller-ledger fact for a provider
  # payout. The database trigger enforces seller, currency, nonzero-ledger,
  # and remaining-amount scope so negative corrections can offset proceeds
  # without changing the allocation's positive reservation contract.
  class SellerPayoutAllocation < Marketplace::ApplicationRecord
    self.table_name = "marketplace_seller_payout_allocations"

    STATUSES = %w[reserved consumed released].freeze

    belongs_to :payout,
               class_name: "Marketplace::SellerPayout",
               inverse_of: :seller_payout_allocations
    belongs_to :seller_ledger_entry,
               class_name: "Marketplace::SellerLedgerEntry",
               inverse_of: :seller_payout_allocations

    validates :payout, :seller_ledger_entry, :amount_minor, :status, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }

    def reserved? = status == "reserved"

    def consumed? = status == "consumed"

    def released? = status == "released"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id payout_id seller_ledger_entry_id amount_minor status consumed_at released_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[payout seller_ledger_entry]
    end
  end
end
