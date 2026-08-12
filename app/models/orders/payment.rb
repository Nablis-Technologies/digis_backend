# frozen_string_literal: true

module Orders
  # One provider attempt for an immutable order total. Payment lifecycle
  # fields may advance later, but amount, currency, Commercial evidence, and
  # retry identity remain fixed for the attempt's entire lifetime.
  class Payment < Orders::ApplicationRecord
    self.table_name = "orders_payments"

    STATUSES = %w[created processing succeeded failed cancelled unknown timeout reversed].freeze
    PROVIDERS = Commercial::FeeComponent::PROVIDERS.freeze
    PAYMENT_METHODS = Commercial::FeeComponent::PAYMENT_METHODS.freeze
    SNAPSHOT_ATTRIBUTES = %w[
      order_id attempt_number provider payment_method amount_minor currency
      commercial_signature buyer_fee_minor organizer_fee_minor provider_fee_minor
      provider_fee_currency idempotency_key settlement_grace_minutes
      settlement_grace_expires_at
    ].freeze

    belongs_to :order, class_name: "Orders::Order", inverse_of: :payments
    has_many :payment_events,
             class_name: "Orders::PaymentEvent",
             inverse_of: :payment,
             dependent: :restrict_with_exception

    before_validation :normalize_fields

    validates :order, presence: true
    validates :attempt_number, numericality: { only_integer: true, in: 1..3 }
    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    validates :payment_method, presence: true, inclusion: { in: PAYMENT_METHODS }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :commercial_signature, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :buyer_fee_minor, :organizer_fee_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :provider_fee_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              allow_nil: true
    validates :provider_fee_currency,
              format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
    validates :idempotency_key, presence: true
    validates :settlement_grace_minutes, numericality: { only_integer: true, in: 3..15 }
    validates :settlement_grace_expires_at, presence: true

    validate :order_payment_state
    validate :order_amount_and_currency
    validate :commercial_signature_matches_attempts
    validate :provider_fee_pair
    validate :accepted_state
    validate :snapshot_immutable

    scope :current, -> { where(superseded_at: nil, status: %w[created processing]) }
    scope :accepted, -> { where.not(accepted_at: nil) }

    def current? = superseded_at.nil? && status.in?(%w[created processing])

    def accepted? = accepted_at.present?

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id order_id attempt_number provider payment_method status amount_minor currency
        commercial_signature buyer_fee_minor organizer_fee_minor provider_fee_minor
        provider_fee_currency idempotency_key provider_reference failure_code raw_status
        settlement_grace_minutes settlement_grace_expires_at accepted_at superseded_at
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[order payment_events]
    end

    private

    def normalize_fields
      self.provider = provider.to_s.strip.downcase.presence
      self.payment_method = payment_method.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.provider_fee_currency = provider_fee_currency.to_s.strip.upcase.presence
      self.provider_reference = provider_reference.to_s.strip.presence
      self.failure_code = failure_code.to_s.strip.presence
      self.raw_status = raw_status.to_s.strip.presence
    end

    def order_payment_state
      return if order.blank? || order.pending_payment?

      errors.add(:order, :invalid)
    end

    def order_amount_and_currency
      return if order.blank?

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
