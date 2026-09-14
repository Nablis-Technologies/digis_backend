# frozen_string_literal: true

module Orders
  # One provider attempt for an immutable order or billing purchase total.
  # Payment lifecycle fields may advance later, but snapshots and retry
  # identity remain fixed for the attempt's entire lifetime.
  class Payment < Orders::ApplicationRecord
    self.table_name = "orders_payments"

    STATUSES = %w[created processing succeeded failed cancelled unknown timeout reversed].freeze
    PROVIDERS = Commercial::FeeComponent::PROVIDERS.freeze
    PAYMENT_METHODS = Commercial::FeeComponent::PAYMENT_METHODS.freeze
    SNAPSHOT_ATTRIBUTES = %w[
      order_id billing_purchase_id attempt_number provider payment_method amount_minor currency
      commercial_signature buyer_fee_minor organizer_fee_minor provider_fee_minor
      provider_fee_currency idempotency_key provider_merchant_reference settlement_grace_minutes
      settlement_grace_expires_at billing_purchase_price_digest
    ].freeze

    belongs_to :order, class_name: "Orders::Order", inverse_of: :payments, optional: true
    belongs_to :billing_purchase, class_name: "Orders::BillingPurchase",
               inverse_of: :payments, optional: true
    has_one :accepted_credit_top_up,
            class_name: "Messaging::CreditTopUp",
            foreign_key: :accepted_payment_id,
            inverse_of: :accepted_payment
    has_many :payment_events,
             class_name: "Orders::PaymentEvent",
             inverse_of: :payment,
             dependent: :restrict_with_exception
    has_many :refunds,
             class_name: "Orders::Refund",
             inverse_of: :payment,
             dependent: :restrict_with_exception
    has_many :cancellation_payment_snapshots,
             class_name: "Events::EventCancellationPayment",
             inverse_of: :payment,
             dependent: :restrict_with_exception
    has_many :finance_ledger_entries,
             class_name: "Finance::LedgerEntry",
             dependent: :restrict_with_exception,
             inverse_of: :payment

    before_validation :normalize_fields

    validates :attempt_number, numericality: { only_integer: true, in: 1..3 }
    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    validates :payment_method, presence: true, inclusion: { in: PAYMENT_METHODS }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :commercial_signature, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
    validates :billing_purchase_price_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
    validates :buyer_fee_minor, :organizer_fee_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :provider_fee_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              allow_nil: true
    validates :provider_fee_currency,
              format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
    validates :checkout_url, format: { with: %r{\Ahttps://[^[:space:]]+\z} }, allow_nil: true
    validates :idempotency_key, presence: true
    validates :provider_merchant_reference, format: { with: /\A[a-z0-9_-]{1,20}\z/ }, allow_nil: true
    validates :settlement_grace_minutes, numericality: { only_integer: true, in: 3..15 }
    validates :settlement_grace_expires_at, presence: true

    validate :order_payment_state
    validate :order_amount_and_currency
    validate :commercial_signature_matches_attempts
    validate :exactly_one_subject
    validate :billing_purchase_amount_and_currency
    validate :subject_digest
    validate :provider_fee_pair
    validate :accepted_state
    validate :snapshot_immutable

    scope :current, -> { where(superseded_at: nil, status: %w[created processing]) }
    scope :accepted, -> { where.not(accepted_at: nil) }

    def current? = superseded_at.nil? && status.in?(%w[created processing])

    def accepted? = accepted_at.present?

    def billing_payment? = billing_purchase_id.present?

    def event_payment? = order_id.present?

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id order_id attempt_number provider payment_method status amount_minor currency
        commercial_signature billing_purchase_price_digest buyer_fee_minor organizer_fee_minor provider_fee_minor
        provider_fee_currency idempotency_key provider_reference failure_code raw_status
        provider_merchant_reference
        billing_purchase_id
        settlement_grace_minutes settlement_grace_expires_at succeeded_at accepted_at superseded_at
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[order billing_purchase payment_events refunds]
    end

    private

    def normalize_fields
      self.provider = provider.to_s.strip.downcase.presence
      self.payment_method = payment_method.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.provider_fee_currency = provider_fee_currency.to_s.strip.upcase.presence
      self.provider_reference = provider_reference.to_s.strip.presence
      self.provider_merchant_reference = provider_merchant_reference.to_s.strip.downcase.presence
      self.checkout_url = checkout_url.to_s.strip.presence
      self.failure_code = failure_code.to_s.strip.presence
      self.raw_status = raw_status.to_s.strip.presence
    end

    def order_payment_state
      # Provider callbacks may arrive after checkout closes; status evidence
      # must remain writable so late successes can be reversed audibly.
      return if billing_purchase_id.present? || order.blank? || order.status.in?(%w[pending_payment paid fulfilled expired cancelled partially_refunded refunded])

      errors.add(:order, :invalid)
    end

    def order_amount_and_currency
      return if order_id.blank? || order.blank?

      errors.add(:amount_minor, :invalid) unless amount_minor == order.total_minor
      errors.add(:currency, :invalid) unless currency == order.charge_currency
    end

    def commercial_signature_matches_attempts
      return if order_id.blank? || commercial_signature.blank?
      payments = order.association(:payments).loaded? ? order.payments : order.payments.load
      return unless payments.any? do |payment|
        payment.id != id && payment.commercial_signature != commercial_signature
      end

      errors.add(:commercial_signature, :invalid)
    end

    def exactly_one_subject
      return if order_id.present? ^ billing_purchase_id.present?

      errors.add(:base, :invalid)
    end

    def billing_purchase_amount_and_currency
      return if billing_purchase_id.blank? || billing_purchase.blank?

      errors.add(:amount_minor, :invalid) unless amount_minor == billing_purchase.amount_minor
      errors.add(:currency, :invalid) unless currency == billing_purchase.currency
    end

    def subject_digest
      if order_id.present?
        errors.add(:commercial_signature, :blank) if commercial_signature.blank?
        errors.add(:billing_purchase_price_digest, :invalid) if billing_purchase_price_digest.present?
      elsif billing_purchase_id.present?
        errors.add(:billing_purchase_price_digest, :blank) if billing_purchase_price_digest.blank?
        errors.add(:commercial_signature, :invalid) if commercial_signature.present?
      end
    end

    def provider_fee_pair
      if provider_fee_minor.present? != provider_fee_currency.present?
        errors.add(:provider_fee_currency, :invalid)
      elsif provider_fee_currency.present? && provider_fee_currency != currency
        errors.add(:provider_fee_currency, :invalid)
      end
    end

    def accepted_state
      errors.add(:accepted_at, :invalid) if accepted_at.present? && status != "succeeded"
    end

    def snapshot_immutable
      return unless persisted?

      SNAPSHOT_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end
  end
end
