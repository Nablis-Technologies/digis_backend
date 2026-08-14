# frozen_string_literal: true

module Finance
  # Immutable organizer settlement fact. The ledger has no mutable balance
  # counter: available balances are derived from these rows and their future
  # payout allocations, while corrections are linked opposite entries.
  class LedgerEntry < Finance::ApplicationRecord
    self.table_name = "finance_ledger_entries"
    self.inheritance_column = nil
    self.record_timestamps = false

    TYPES = %w[sale platform_fee processing_fee refund chargeback adjustment payout].freeze
    NEGATIVE_TYPES = %w[platform_fee processing_fee refund chargeback payout].freeze
    SNAPSHOT_ATTRIBUTES = %w[
      organization_id event_id order_id payment_id refund_id reverses_entry_id type amount_minor currency
      available_at idempotency_key description
    ].freeze

    belongs_to :organization, class_name: "Organizations::Organization",
               inverse_of: :finance_ledger_entries
    belongs_to :event, class_name: "Events::Event", optional: true
    belongs_to :order, class_name: "Orders::Order", optional: true
    belongs_to :payment, class_name: "Orders::Payment", optional: true
    belongs_to :refund, class_name: "Orders::Refund", optional: true
    belongs_to :reverses_entry,
               class_name: "Finance::LedgerEntry",
               optional: true,
               inverse_of: :reversal
    has_one :reversal,
            class_name: "Finance::LedgerEntry",
            foreign_key: :reverses_entry_id,
            inverse_of: :reverses_entry
    has_many :payout_allocations,
             class_name: "Finance::PayoutAllocation",
             dependent: :restrict_with_exception,
             inverse_of: :ledger_entry

    validates :organization, :type, :amount_minor, :currency, :available_at, :idempotency_key, :created_at,
              presence: true
    validates :type, inclusion: { in: TYPES }
    validates :amount_minor, numericality: { only_integer: true, other_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :idempotency_key, uniqueness: true

    validate :event_required_for_event_facts
    validate :event_organization_scope
    validate :amount_sign
    validate :reference_scope
    validate :currency_scope
    validate :reversal_scope

    before_update :prevent_mutation
    before_destroy :prevent_mutation

    scope :available, ->(at = Time.current) { where("available_at <= ?", at) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id event_id order_id payment_id refund_id reverses_entry_id type amount_minor currency
         available_at idempotency_key description created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization event order payment refund reverses_entry reversal]
    end

    private

    def event_required_for_event_facts
      return if event_id.present? || type == "payout"
      return if type == "adjustment" && reversal_without_event?

      errors.add(:event, :blank)
    end

    def amount_sign
      return if amount_minor.blank? || type == "adjustment"
      return if type == "sale" && amount_minor.positive?
      return if NEGATIVE_TYPES.include?(type) && amount_minor.negative?

      errors.add(:amount_minor, :invalid)
    end

    def event_organization_scope
      return if event_id.blank? || organization_id.blank?
      return if Events::Event.where(id: event_id, organization_id:).exists?

      errors.add(:organization, :invalid)
    end

    def reference_scope
      validate_order_scope
      validate_payment_scope
      validate_refund_scope
    end

    def validate_order_scope
      return if order_id.blank?
      event_id_for_order = Orders::Order.where(id: order_id).pick(:event_id)
      errors.add(:order, :invalid) unless event_id_for_order == event_id
    end

    def validate_payment_scope
      return if payment_id.blank?
      payment_order_id = Orders::Payment.where(id: payment_id).pick(:order_id)
      errors.add(:payment, :invalid) unless payment_order_id == order_id
    end

    def validate_refund_scope
      return if refund_id.blank?
      refund_payment_id = Orders::Refund.where(id: refund_id).pick(:payment_id)
      errors.add(:refund, :invalid) unless refund_payment_id == payment_id
    end

    def currency_scope
      return if order_id.blank? || currency.blank?
      return if Orders::Order.where(id: order_id, settlement_currency: currency).exists?

      errors.add(:currency, :invalid)
    end

    def reversal_scope
      return if reverses_entry_id.blank?
      return errors.add(:reverses_entry, :invalid) if reverses_entry_id == id

      original = Finance::LedgerEntry.find_by(id: reverses_entry_id)
      return errors.add(:reverses_entry, :invalid) unless original
      return errors.add(:type, :invalid) unless type == "adjustment"
      return errors.add(:currency, :invalid) unless currency == original.currency
      return errors.add(:amount_minor, :invalid) unless amount_minor == -original.amount_minor
      return errors.add(:organization, :invalid) unless organization_id == original.organization_id
      errors.add(:event, :invalid) unless event_id == original.event_id
    end

    def reversal_without_event?
      return false if reverses_entry_id.blank?

      Finance::LedgerEntry.where(id: reverses_entry_id, type: "payout", event_id: nil).exists?
    end

    def prevent_mutation
      raise ActiveRecord::ReadOnlyRecord, I18n.t("errors.messages.immutable")
    end
  end
end
