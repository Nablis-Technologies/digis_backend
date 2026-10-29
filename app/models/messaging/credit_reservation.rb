# frozen_string_literal: true

module Messaging
  # Holds channel credits for one campaign aggregate or recipient/source identity.
  class CreditReservation < Messaging::ApplicationRecord
    self.table_name = "messaging_credit_reservations"

    CHANNELS = CreditAccount::CHANNELS
    STATUSES = %w[reserved consumed released refunded expired].freeze
    SOURCE_TYPES = %w[Messaging::Campaign Messaging::CampaignRecipient].freeze

    belongs_to :credit_account,
               class_name: "Messaging::CreditAccount",
               inverse_of: :reservations
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :rate_version,
               class_name: "Messaging::CreditRateVersion",
               inverse_of: :reservations
    has_many :allocations,
             class_name: "Messaging::CampaignCreditAllocation",
             foreign_key: :credit_reservation_id,
             inverse_of: :credit_reservation,
             dependent: :restrict_with_exception

    before_validation :normalize_fields
    validate :immutable_snapshot, on: :update
    validate :source_pair
    validate :account_organization_matches
    validate :rate_scope_matches

    validates :credit_account, :organization, :rate_version, :channel, :quantity,
      :status, :idempotency_key_digest, :reserved_at, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :source_type, inclusion: { in: SOURCE_TYPES }, allow_nil: true
    validates :idempotency_key_digest, format: { with: /\A[0-9a-f]{64}\z/ }

    def terminal? = status != "reserved"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id credit_account_id organization_id rate_version_id source_type source_id channel quantity status
         idempotency_key_digest reserved_at resolved_at resolution_code created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[credit_account organization rate_version allocations]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.source_type = source_type.to_s.strip.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.resolution_code = resolution_code.to_s.strip.presence
    end

    def source_pair
      return if source_type.present? == source_id.present?

      errors.add(:source_id, :invalid)
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

    def immutable_snapshot
      return unless persisted?

      %w[credit_account_id organization_id rate_version_id source_type source_id channel quantity reserved_at].each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end
  end
end
