# frozen_string_literal: true

module Orders
  # Non-event billing subject used for platform purchases such as Messaging
  # credit top-ups. It shares provider payment contracts without creating a
  # fake event, ticket, or organizer-sale ledger entry.
  class BillingPurchase < Orders::ApplicationRecord
    self.table_name = "orders_billing_purchases"

    KINDS = %w[messaging_credit_top_up featured_placement].freeze
    STATUSES = %w[created pending_payment paid cancelled failed reversed].freeze
    SOURCE_TYPES = %w[Messaging::CreditTopUp Marketing::FeaturedPlacement].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :requested_by, class_name: "Core::User"
    has_many :payments,
             class_name: "Orders::Payment",
             foreign_key: :billing_purchase_id,
             inverse_of: :billing_purchase,
             dependent: :restrict_with_exception
    before_validation :normalize_fields

    validates :organization, :requested_by, :kind, :source_type, :source_id,
      :currency, :amount_minor, :price_digest, :status,
      :idempotency_key_digest, :expires_at, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :source_type, inclusion: { in: SOURCE_TYPES }
    validates :status, inclusion: { in: STATUSES }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :price_digest, :idempotency_key_digest, format: { with: /\A[0-9a-f]{64}\z/ }

    def paid? = status == "paid"

    def reversed? = status == "reversed"

    def closed? = status.in?(%w[cancelled failed reversed])

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id requested_by_id kind source_type source_id currency amount_minor
         price_digest status provider_reference idempotency_key_digest expires_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization requested_by payments]
    end

    private

    def normalize_fields
      self.kind = kind.to_s.strip.downcase.presence
      self.source_type = source_type.to_s.strip.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.provider_reference = provider_reference.to_s.strip.presence
      self.price_digest = price_digest.to_s.strip.downcase.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
    end
  end
end
