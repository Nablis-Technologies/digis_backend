# frozen_string_literal: true

module Marketplace
  # Append-only seller balance fact. Balances are derived from these signed
  # rows and allocations; corrections are new rows linked to the original
  # rather than mutations to historical resale economics.
  class SellerLedgerEntry < Marketplace::ApplicationRecord
    self.table_name = "marketplace_seller_ledger_entries"
    self.inheritance_column = nil
    self.record_timestamps = false

    TYPES = %w[resale_proceeds marketplace_fee cancellation_reversal chargeback adjustment payout].freeze
    NEGATIVE_TYPES = %w[marketplace_fee chargeback payout].freeze

    belongs_to :seller_user, class_name: "Core::User"
    belongs_to :event, class_name: "Events::Event"
    belongs_to :resale_sale, class_name: "Marketplace::ResaleSale", optional: true
    belongs_to :seller_payout, class_name: "Marketplace::SellerPayout", optional: true
    belongs_to :reverses_entry,
               class_name: "Marketplace::SellerLedgerEntry",
               optional: true,
               inverse_of: :reversal
    has_one :reversal,
            class_name: "Marketplace::SellerLedgerEntry",
            foreign_key: :reverses_entry_id,
            inverse_of: :reverses_entry
    has_many :seller_payout_allocations,
             class_name: "Marketplace::SellerPayoutAllocation",
             dependent: :restrict_with_exception,
             inverse_of: :seller_ledger_entry

    validates :seller_user, :event, :type, :amount_minor, :currency, :available_at,
              :idempotency_key, :created_at, presence: true
    validates :type, inclusion: { in: TYPES }
    validates :amount_minor, numericality: { only_integer: true, other_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :idempotency_key, uniqueness: true

    validate :amount_sign
    validate :reference_shape
    validate :sale_scope
    validate :reversal_scope

    before_update :prevent_mutation
    before_destroy :prevent_mutation

    def positive?
      amount_minor.positive?
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id seller_user_id event_id resale_sale_id seller_payout_id reverses_entry_id type amount_minor currency
         available_at idempotency_key description created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[seller_user event resale_sale seller_payout reverses_entry reversal seller_payout_allocations]
    end

    private

    def amount_sign
      return if amount_minor.blank?
      return if type == "resale_proceeds" && amount_minor.positive?
      return if NEGATIVE_TYPES.include?(type) && amount_minor.negative?
      return if %w[cancellation_reversal adjustment].include?(type)

      errors.add(:amount_minor, :invalid)
    end

    def reference_shape
      if %w[resale_proceeds marketplace_fee cancellation_reversal chargeback].include?(type)
        errors.add(:resale_sale, :blank) if resale_sale_id.blank?
      elsif type == "payout"
        errors.add(:seller_payout, :blank) if seller_payout_id.blank?
      elsif resale_sale_id.present? || seller_payout_id.present?
        errors.add(:base, :invalid)
      end
    end

    def sale_scope
      return if resale_sale_id.blank?

      sale_event_id, sale_seller_id, sale_currency = if association(:resale_sale).loaded?
        [ resale_sale&.event_id, resale_sale&.seller_user_id, resale_sale&.currency ]
      else
        Marketplace::ResaleSale.where(id: resale_sale_id).pick(:event_id, :seller_user_id, :currency)
      end
      errors.add(:event, :invalid) unless sale_event_id == event_id
      errors.add(:seller_user, :invalid) unless sale_seller_id == seller_user_id
      errors.add(:currency, :invalid) unless sale_currency == currency
    end

    def reversal_scope
      return if reverses_entry_id.blank?
      return errors.add(:reverses_entry, :invalid) if reverses_entry_id == id

      original = if association(:reverses_entry).loaded?
        reverses_entry
      else
        self.class.find_by(id: reverses_entry_id)
      end
      return errors.add(:reverses_entry, :invalid) unless original

      original_amount = original.amount_minor
      original_currency = original.currency
      original_seller_id = original.seller_user_id
      original_event_id = original.event_id
      errors.add(:amount_minor, :invalid) unless amount_minor == -original_amount
      errors.add(:currency, :invalid) unless currency == original_currency
      errors.add(:seller_user, :invalid) unless seller_user_id == original_seller_id
      errors.add(:event, :invalid) unless event_id == original_event_id
    end

    def prevent_mutation
      raise ActiveRecord::ReadOnlyRecord, I18n.t("errors.messages.immutable")
    end
  end
end
