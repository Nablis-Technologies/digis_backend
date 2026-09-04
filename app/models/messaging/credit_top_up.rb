# frozen_string_literal: true

module Messaging
  # Immutable purchase intent that receives credits only after accepted payment.
  class CreditTopUp < Messaging::ApplicationRecord
    self.table_name = "messaging_credit_top_ups"

    CHANNELS = CreditAccount::CHANNELS
    STATUSES = %w[created pending_payment paid cancelled failed reversed].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :credit_account,
               class_name: "Messaging::CreditAccount",
               inverse_of: :top_ups
    belongs_to :rate_version,
               class_name: "Messaging::CreditRateVersion",
               inverse_of: :top_ups
    belongs_to :billing_purchase,
               class_name: "Orders::BillingPurchase",
               foreign_key: :orders_billing_purchase_id,
               optional: true,
               inverse_of: :credit_top_up
    belongs_to :accepted_payment,
               class_name: "Orders::Payment",
               optional: true,
               inverse_of: :accepted_credit_top_up

    before_validation :normalize_fields
    validate :immutable_snapshot, on: :update
    validate :account_organization_matches
    validate :rate_scope_matches

    validates :organization, :credit_account, :rate_version, :channel, :quantity,
      :currency, :amount_minor, :price_digest, :status, :idempotency_key_digest,
      :request_digest, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :price_digest, :idempotency_key_digest, :request_digest,
      format: { with: /\A[0-9a-f]{64}\z/ }

    def terminal? = status.in?(%w[paid cancelled failed reversed])

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id credit_account_id rate_version_id orders_billing_purchase_id accepted_payment_id channel
         quantity currency amount_minor price_digest status provider_reference idempotency_key_digest request_digest created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization credit_account rate_version billing_purchase accepted_payment]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.price_digest = price_digest.to_s.strip.downcase.presence
      self.provider_reference = provider_reference.to_s.strip.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.request_digest = request_digest.to_s.strip.downcase.presence
    end

    def immutable_snapshot
      return unless persisted?

      %w[organization_id credit_account_id rate_version_id channel quantity currency amount_minor price_digest request_digest].each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def account_organization_matches
      return if credit_account.blank? || organization_id.blank?
      return if credit_account.organization_id == organization_id

      errors.add(:organization_id, :invalid)
    end

    def rate_scope_matches
      return if rate_version.blank? || organization_id.blank?
      return if rate_version.organization_id.nil? || rate_version.organization_id == organization_id

      errors.add(:rate_version_id, :invalid)
    end
  end
end
