# frozen_string_literal: true

module Marketplace
  # Stores an encrypted seller bank destination. Raw beneficiary values are
  # available only to the verified payout command at provider dispatch time.
  class SellerPayoutAccount < Marketplace::ApplicationRecord
    self.table_name = "marketplace_seller_payout_accounts"
    self.inheritance_column = nil

    include Core::AuditableModel

    TYPES = %w[bank].freeze
    PROVIDERS = %w[chapa].freeze
    STATUSES = %w[pending_verification verified suspended closed].freeze
    VERIFICATION_SOURCES = %w[provider test_fixture manual].freeze

    belongs_to :user, class_name: "Core::User"
    belongs_to :verified_by, class_name: "Core::User", optional: true
    has_many :seller_payouts,
             class_name: "Marketplace::SellerPayout",
             foreign_key: :seller_payout_account_id,
             dependent: :restrict_with_exception

    encrypts :account_number_ciphertext, :account_label_ciphertext, :holder_name_ciphertext

    before_validation :normalize_fields

    validates :user, :type, :provider, :bank_code, :account_number, :account_number_digest,
              :holder_name, :status, presence: true
    validates :type, inclusion: { in: TYPES }
    validates :provider, inclusion: { in: PROVIDERS }
    validates :status, inclusion: { in: STATUSES }
    validates :verification_source, inclusion: { in: VERIFICATION_SOURCES }, allow_nil: true
    validates :bank_code, numericality: { only_integer: true, greater_than: 0 }
    validates :account_number_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validate :verification_metadata
    validate :default_requires_verified

    def account_number = account_number_ciphertext

    def account_number=(value)
      self.account_number_ciphertext = value.to_s.strip.presence
    end

    def account_label = account_label_ciphertext

    def account_label=(value)
      self.account_label_ciphertext = value.to_s.strip.presence
    end

    def holder_name = holder_name_ciphertext

    def holder_name=(value)
      self.holder_name_ciphertext = value.to_s.strip.presence
    end

    def verified?
      status == "verified"
    end

    def suspended? = status == "suspended"

    def closed? = status == "closed"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id user_id type provider bank_code status verification_source is_default
         verified_at last_used_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user verified_by seller_payouts]
    end

    private

    def normalize_fields
      self.type = type.to_s.strip.downcase.presence
      self.provider = provider.to_s.strip.downcase.presence
      self.bank_code = bank_code.to_i if bank_code.present?
      self.status = status.to_s.strip.downcase.presence
      self.verification_source = verification_source.to_s.strip.downcase.presence
    end

    def verification_metadata
      if status == "verified"
        errors.add(:verified_at, :blank) if verified_at.blank?
        errors.add(:verification_source, :blank) if verification_source.blank?
        errors.add(:verified_by, :blank) if verification_source == "manual" && verified_by.blank?
      else
        errors.add(:verified_at, :invalid) if verified_at.present?
        errors.add(:verification_source, :invalid) if verification_source.present?
        errors.add(:verified_by, :invalid) if verified_by.present?
      end
    end

    def default_requires_verified
      return unless is_default?
      return if verified?

      errors.add(:is_default, :invalid)
    end
  end
end
