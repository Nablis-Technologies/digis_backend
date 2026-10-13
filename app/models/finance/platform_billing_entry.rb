# frozen_string_literal: true

module Finance
  # Immutable platform-side billing facts, separate from organizer settlement.
  class PlatformBillingEntry < Finance::ApplicationRecord
    self.table_name = "finance_platform_billing_entries"
    self.inheritance_column = nil

    TYPES = %w[featured_placement_charge provider_fee featured_placement_refund].freeze

    belongs_to :billing_purchase, class_name: "Orders::BillingPurchase"
    belongs_to :payment, class_name: "Orders::Payment"
    belongs_to :refund, class_name: "Orders::Refund", optional: true

    before_validation :normalize_fields
    validate :entry_shape
    validate :source_scope
    validate :immutable, on: :update

    validates :billing_purchase_id, :payment_id, presence: true
    validates :type, inclusion: { in: TYPES }
    validates :amount_minor, numericality: { only_integer: true }
    validates :currency, inclusion: { in: [ "ETB" ] }
    validates :idempotency_key, format: { with: /\A[0-9a-f]{64}\z/ }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id billing_purchase_id payment_id refund_id type amount_minor currency idempotency_key created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[billing_purchase payment refund]
    end

    private

    def normalize_fields
      self.type = type.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.idempotency_key = idempotency_key.to_s.strip.downcase.presence
    end

    def entry_shape
      case type
      when "featured_placement_charge"
        errors.add(:amount_minor, :invalid) unless amount_minor&.positive?
        errors.add(:refund_id, :invalid) if refund_id.present?
      when "provider_fee"
        errors.add(:amount_minor, :invalid) unless amount_minor&.negative?
        errors.add(:refund_id, :invalid) if refund_id.present?
      when "featured_placement_refund"
        errors.add(:amount_minor, :invalid) unless amount_minor&.negative?
        errors.add(:refund, :blank) if refund_id.blank?
      end
    end

    def source_scope
      return if billing_purchase_id.blank? || payment_id.blank?

      purchase = billing_purchase
      payment_record = payment
      purchase_matches = purchase&.source_type == "Marketing::FeaturedPlacement"
      payment_matches = payment_record&.billing_purchase_id == billing_purchase_id
      return if purchase_matches && payment_matches && refund_scope_matches?

      errors.add(:billing_purchase_id, :invalid)
    end

    def refund_scope_matches?
      return true if refund_id.blank? && type != "featured_placement_refund"

      refund_record = refund
      refund_record.present? && refund_record.payment_id == payment_id &&
        refund_record.billing_purchase_id == billing_purchase_id && refund_record.status == "succeeded" &&
        refund_record.type == "billing_purchase_refund"
    end

    def immutable
      errors.add(:base, :immutable)
    end
  end
end
