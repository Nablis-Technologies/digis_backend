# frozen_string_literal: true

module Finance
  # Organization-owned beneficiary details used only for verified provider
  # transfers. Account fields are encrypted; the keyed digest is the only
  # searchable representation of the account number.
  class PayoutAccount < Finance::ApplicationRecord
    self.table_name = "finance_payout_accounts"
    self.inheritance_column = nil

    include Core::AuditableModel

    TYPES = %w[bank mobile_money].freeze
    PROVIDERS = %w[chapa].freeze
    STATUSES = %w[pending_verification verified suspended closed].freeze
    VERIFICATION_SOURCES = %w[provider test_fixture manual].freeze

    belongs_to :organization, class_name: "Organizations::Organization",
               inverse_of: :finance_payout_accounts
    belongs_to :verified_by, class_name: "Core::User", optional: true
    has_many :payouts,
             class_name: "Finance::Payout",
             foreign_key: :payout_account_id,
             dependent: :restrict_with_exception,
             inverse_of: :payout_account

    encrypts :account_number_ciphertext, :account_name_ciphertext, :account_label_ciphertext

    before_validation :normalize_fields

    validates :organization, :type, :provider, :bank_code, :account_number_digest, :status, presence: true
    validates :type, inclusion: { in: TYPES }
    validates :provider, inclusion: { in: PROVIDERS }
    validates :status, inclusion: { in: STATUSES }
    validates :verification_source, inclusion: { in: VERIFICATION_SOURCES }, allow_nil: true
    validates :bank_code, numericality: { only_integer: true, greater_than: 0 }
    validates :account_number, presence: true
    validates :account_number_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validate :default_requires_verified
    validate :verification_metadata

    def account_number = account_number_ciphertext

    def account_number=(value)
      self.account_number_ciphertext = value.to_s.strip.presence
    end

    def account_name = account_name_ciphertext

    def account_name=(value)
      self.account_name_ciphertext = value.to_s.strip.presence
    end

    def account_label = account_label_ciphertext

    def account_label=(value)
      self.account_label_ciphertext = value.to_s.strip.presence
    end

    def verified? = status == "verified"

    def suspended? = status == "suspended"

    def closed? = status == "closed"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id type provider bank_code status verification_source
         is_default verified_at last_used_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization verified_by payouts]
    end

    private

    def normalize_fields
      self.type = type.to_s.strip.downcase.presence
      self.provider = provider.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.verification_source = verification_source.to_s.strip.downcase.presence
      self.bank_code = bank_code.to_i if bank_code.present?
    end

    def default_requires_verified
      return unless is_default?
      return if verified?

      errors.add(:is_default, :invalid)
    end

    def verification_metadata
      if verified?
        errors.add(:verified_at, :blank) if verified_at.blank?
        errors.add(:verification_source, :blank) if verification_source.blank?
        errors.add(:verified_by, :blank) if verification_source == "manual" && verified_by.blank?
      else
        errors.add(:verified_at, :invalid) if verified_at.present?
        errors.add(:verification_source, :invalid) if verification_source.present?
        errors.add(:verified_by, :invalid) if verified_by.present?
      end
    end
  end
end
