# frozen_string_literal: true

module Messaging
  # Immutable, versioned organizer-facing price definition for one channel.
  class CreditRateVersion < Messaging::ApplicationRecord
    self.table_name = "messaging_credit_rate_versions"

    CHANNELS = CreditAccount::CHANNELS
    STATUSES = %w[draft active retired].freeze

    belongs_to :organization,
               class_name: "Organizations::Organization",
               optional: true
    belongs_to :created_by, class_name: "Core::User", optional: true
    belongs_to :activated_by, class_name: "Core::User", optional: true
    belongs_to :retired_by, class_name: "Core::User", optional: true
    has_many :ledger_entries,
             class_name: "Messaging::CreditLedgerEntry",
             foreign_key: :rate_version_id,
             inverse_of: :rate_version,
             dependent: :restrict_with_exception
    has_many :reservations,
             class_name: "Messaging::CreditReservation",
             foreign_key: :rate_version_id,
             inverse_of: :rate_version,
             dependent: :restrict_with_exception
    has_many :top_ups,
             class_name: "Messaging::CreditTopUp",
             foreign_key: :rate_version_id,
             inverse_of: :rate_version,
             dependent: :restrict_with_exception

    before_validation :normalize_fields
    validate :volume_tiers_are_valid
    validate :immutable_snapshot, on: :update

    validates :channel, :version, :currency, :unit_price_minor,
      :effective_from, :status, :idempotency_key_digest, :request_digest, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :unit_price_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :provider_cost_minor,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :country_code, format: { with: /\A[A-Z]{2}\z/ }, allow_nil: true
    validates :idempotency_key_digest, :request_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validate :state_metadata

    scope :active_at, ->(time = Time.current) {
      where(status: "active")
        .where("effective_from <= ?", time)
        .where("effective_until IS NULL OR effective_until > ?", time)
    }

    def draft? = status == "draft"

    def active? = status == "active"

    def retired? = status == "retired"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id channel version currency unit_price_minor provider_cost_minor country_code
         effective_from effective_until status created_by_id activated_by_id retired_by_id activated_at retired_at
         idempotency_key_digest request_digest created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization created_by activated_by retired_by ledger_entries reservations top_ups]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.country_code = country_code.to_s.strip.upcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.volume_tiers = [] if volume_tiers.nil?
    end

    def volume_tiers_are_valid
      if volume_tiers.is_a?(Array) && volume_tiers.all? { |tier| valid_tier?(tier) }
        ranges = volume_tiers.map { |tier| [ tier.fetch("from").to_i, tier["to"]&.to_i ] }
        return if ranges.sort_by(&:first).each_cons(2).none? { |left, right| ranges_overlap?(left, right) }
      end

      errors.add(:volume_tiers, :invalid)
    end

    def valid_tier?(tier)
      return false unless tier.is_a?(Hash)

      from = tier["from"].to_i
      to = tier["to"]
      from.positive? && (to.nil? || to.to_i >= from) && tier["unit_price_minor"].to_i.positive?
    end

    def ranges_overlap?(left, right)
      left_end = left.last || Float::INFINITY
      right_end = right.last || Float::INFINITY
      left.first <= right_end && right.first <= left_end
    end

    def immutable_snapshot
      return unless persisted?

      %w[organization_id channel version currency unit_price_minor provider_cost_minor country_code
         volume_tiers effective_from effective_until idempotency_key_digest request_digest].each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def state_metadata
      case status
      when "draft"
        errors.add(:activated_at, :present) if activated_at.present?
        errors.add(:retired_at, :present) if retired_at.present?
      when "active"
        errors.add(:activated_at, :blank) if activated_at.blank?
        errors.add(:retired_at, :present) if retired_at.present?
      when "retired"
        errors.add(:activated_at, :blank) if activated_at.blank?
        errors.add(:retired_at, :blank) if retired_at.blank?
      end
    end
  end
end
