# frozen_string_literal: true

module Core
  # Versioned, append-only retention rules for sensitive platform data. Once a
  # policy is active its payload is immutable; it may only be retired so stored
  # evidence can always identify the governing policy.
  class DataRetentionPolicy < Core::ApplicationRecord
    self.table_name = "core_data_retention_policies"

    include Core::AuditableModel

    CATEGORIES = %w[
      registration_free_text registration_structured consent_evidence security_audit financial_record
    ].freeze
    ACTIONS = %w[erase_payload retain].freeze
    STATUSES = %w[draft active retired].freeze

    belongs_to :created_by, class_name: "Core::User"

    scope :active, -> { where(status: "active") }
    scope :effective_at, ->(time) { where(effective_at: ..time) }

    validates :category, presence: true, inclusion: { in: CATEGORIES }
    validates :version, numericality: { only_integer: true, greater_than: 0 },
                       uniqueness: { scope: %i[category jurisdiction_code] }
    validates :retention_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :action, presence: true, inclusion: { in: ACTIONS }
    validates :status, presence: true, inclusion: { in: STATUSES },
                      uniqueness: { scope: %i[category jurisdiction_code], if: :active? }
    validates :effective_at, presence: true, if: :active?
    validate :retention_days_required_for_erasure
    validate :version_is_monotonic
    validate :status_transition
    validate :immutable_payload

    before_validation :normalize_jurisdiction_code

    def self.ransackable_attributes(_auth_object = nil)
      %w[id category jurisdiction_code version retention_days action status effective_at created_by_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[created_by]
    end

    private

    def active?
      status == "active"
    end

    def normalize_jurisdiction_code
      self.jurisdiction_code = jurisdiction_code.to_s.strip.upcase.presence
    end

    def retention_days_required_for_erasure
      return unless action == "erase_payload" && retention_days.blank?

      errors.add(:retention_days, :blank)
    end

    def version_is_monotonic
      return if category.blank? || version.blank?
      return if persisted? && !monotonicity_change?

      relation = self.class.where(category:, jurisdiction_code:)
      relation = relation.where.not(id: id) if persisted?
      previous_version = relation.maximum(:version)
      return if previous_version.blank? || version > previous_version

      errors.add(:version, :greater_than, count: previous_version)
    end

    def monotonicity_change?
      return true unless persisted?

      will_save_change_to_version? ||
        will_save_change_to_category? ||
        will_save_change_to_jurisdiction_code? ||
        (will_save_change_to_status? && status == "active")
    end

    def status_transition
      return unless persisted? && will_save_change_to_status?

      case status_in_database
      when "active"
        # Active policy content cannot be edited or reactivated after retirement.
        errors.add(:status, :invalid) unless status == "retired"
      when "retired"
        errors.add(:status, :invalid)
      end
    end

    def immutable_payload
      return unless persisted? && %w[active retired].include?(status_in_database)
      return if (changes.keys - [ "status" ]).empty?

      errors.add(:base, :immutable)
    end
  end
end
