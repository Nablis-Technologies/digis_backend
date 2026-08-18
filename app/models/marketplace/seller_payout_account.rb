# frozen_string_literal: true

module Marketplace
  # Stores a tokenized seller destination. Raw bank or mobile-money
  # credentials never enter this table; the provider-owned account token is
  # the only payout identifier retained by the platform.
  class SellerPayoutAccount < Marketplace::ApplicationRecord
    self.table_name = "marketplace_seller_payout_accounts"
    self.inheritance_column = nil

    include Core::AuditableModel

    TYPES = %w[mobile_money bank].freeze
    PROVIDERS = %w[telebirr chapa bank].freeze
    STATUSES = %w[pending_verification verified suspended closed].freeze

    belongs_to :user, class_name: "Core::User"
    has_many :seller_payouts,
             class_name: "Marketplace::SellerPayout",
             foreign_key: :seller_payout_account_id,
             dependent: :restrict_with_exception

    encrypts :account_label_ciphertext, :holder_name_ciphertext

    before_validation :normalize_fields

    validates :user, :type, :provider, :account_token, :holder_name_ciphertext, :status, presence: true
    validates :type, inclusion: { in: TYPES }
    validates :provider, inclusion: { in: PROVIDERS }
    validates :status, inclusion: { in: STATUSES }
    validates :account_token, uniqueness: { scope: :provider }
    validate :verification_metadata

    def verified?
      status == "verified"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id user_id type provider status verified_at last_used_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user seller_payouts]
    end

    private

    def normalize_fields
      self.type = type.to_s.strip.downcase.presence
      self.provider = provider.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.account_token = account_token.to_s.strip.presence
    end

    def verification_metadata
      if status == "verified"
        errors.add(:verified_at, :blank) if verified_at.blank?
      elsif verified_at.present?
        errors.add(:verified_at, :invalid)
      end
    end
  end
end
