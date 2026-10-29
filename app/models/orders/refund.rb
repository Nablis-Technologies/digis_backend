# frozen_string_literal: true

module Orders
  # Durable provider-refund obligation. A payment reversal is created inside
  # the acceptance transaction, then submitted by a job after commit; this
  # keeps provider I/O outside the payment/order lock set and makes retries
  # idempotent by the unaccepted payment ID.
  class Refund < Orders::ApplicationRecord
    self.table_name = "orders_refunds"
    self.inheritance_column = nil

    TYPES = %w[item_refund payment_reversal billing_purchase_refund].freeze
    STATUSES = %w[created pending_funds processing manual_review succeeded failed].freeze
    OUTSTANDING_STATUSES = %w[created pending_funds processing manual_review succeeded].freeze
    PAYMENT_REVERSAL_REASONS = %w[duplicate_payment late_payment superseded_attempt event_cancelled].freeze
    BILLING_PURCHASE_REFUND_REASONS = %w[featured_placement_cancelled event_cancelled].freeze

    belongs_to :payment, class_name: "Orders::Payment", inverse_of: :refunds
    belongs_to :billing_purchase, class_name: "Orders::BillingPurchase", optional: true
    belongs_to :event_cancellation,
               class_name: "Events::EventCancellation",
               optional: true
    belongs_to :manual_resolved_by, class_name: "Core::User", optional: true
    has_many :refund_items,
             class_name: "Orders::RefundItem",
             inverse_of: :refund,
             dependent: :restrict_with_exception
    has_many :finance_ledger_entries,
             class_name: "Finance::LedgerEntry",
             dependent: :restrict_with_exception,
             inverse_of: :refund

    before_validation :normalize_fields

    validates :payment, :type, :idempotency_key, :amount_minor, :currency, :status, :reason_code,
              presence: true
    validates :type, inclusion: { in: TYPES }
    validates :status, inclusion: { in: STATUSES }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :idempotency_key, uniqueness: true
    validates :provider_fee_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              allow_nil: true
    validates :provider_fee_currency,
              format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
    validates :pending_reason, presence: true, if: -> { status == "pending_funds" }

    validate :payment_currency_matches
    validate :provider_fee_pair
    validate :payment_reversal_payment_state
    validate :payment_reversal_shape
    validate :billing_purchase_refund_shape
    validate :billing_purchase_refund_reason
    validate :manual_resolution_state

    def succeeded? = status == "succeeded"

    def pending? = status.in?(%w[created pending_funds processing])

    def self.ransackable_attributes(_auth_object = nil)
      %w[id payment_id billing_purchase_id event_cancellation_id type idempotency_key provider_reference amount_minor currency status
         provider_fee_minor provider_fee_currency provider_fee_recorded_at pending_reason next_retry_at reason_code
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[payment billing_purchase event_cancellation refund_items manual_resolved_by]
    end

    private

    def normalize_fields
      self.type = type.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.provider_fee_currency = provider_fee_currency.to_s.strip.upcase.presence
      self.provider_reference = provider_reference.to_s.strip.presence
      self.reason_code = reason_code.to_s.strip.downcase.presence
      self.manual_resolution_reason = manual_resolution_reason.to_s.strip.presence
      self.manual_evidence_reference = manual_evidence_reference.to_s.strip.presence
    end

    def payment_currency_matches
      return if payment.blank? || currency.blank?
      return if payment.currency == currency

      errors.add(:currency, :invalid)
    end

    def provider_fee_pair
      known = provider_fee_minor.present? || provider_fee_currency.present? || provider_fee_recorded_at.present?
      return unless known
      return if provider_fee_minor.present? && provider_fee_currency.present? && provider_fee_recorded_at.present?

      errors.add(:provider_fee_minor, :invalid)
    end

    def payment_reversal_shape
      return unless type == "payment_reversal"
      return if PAYMENT_REVERSAL_REASONS.include?(reason_code)

      errors.add(:reason_code, :inclusion)
    end

    def payment_reversal_payment_state
      return unless type == "payment_reversal" && payment.present?
      return if payment.status == "succeeded" && amount_minor == payment.amount_minor &&
        (payment.accepted_at.nil? || payment.billing_payment?)

      errors.add(:payment, :invalid)
    end

    def billing_purchase_refund_shape
      if type == "billing_purchase_refund"
        purchase_id = Orders::Payment.where(id: payment_id).pick(:billing_purchase_id)
        valid = billing_purchase_id.present? && event_cancellation_id.blank? &&
          billing_purchase_id == purchase_id &&
          Orders::BillingPurchase.where(id: billing_purchase_id).exists?
        errors.add(:billing_purchase_id, :invalid) unless valid
      elsif billing_purchase_id.present?
        errors.add(:billing_purchase_id, :invalid)
      end
    end

    def manual_resolution_state
      values = [ manual_resolved_by_id, manual_resolution_reason, manual_evidence_reference, manual_resolved_at ]
      return if values.all?(&:blank?)
      return if status == "succeeded" && values.all?(&:present?) && manual_resolution_reason.length <= 255 &&
        manual_evidence_reference.match?(/\A[A-Za-z0-9._:\/-]{1,120}\z/)

      errors.add(:manual_resolved_at, :invalid)
    end

    def billing_purchase_refund_reason
      return unless type == "billing_purchase_refund"
      return if BILLING_PURCHASE_REFUND_REASONS.include?(reason_code)

      errors.add(:reason_code, :inclusion)
    end
  end
end
