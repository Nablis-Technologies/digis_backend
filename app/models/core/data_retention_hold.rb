# frozen_string_literal: true

module Core
  # A time-bounded legal or operational hold that suspends retention processing
  # for exactly one event, registration, or user. Holds are idempotent by their
  # client-supplied key so repeated commands do not create duplicate overrides.
  class DataRetentionHold < Core::ApplicationRecord
    self.table_name = "core_data_retention_holds"

    CATEGORIES = Core::DataRetentionPolicy::CATEGORIES
    REASON_CODES = %w[
      legal_hold litigation regulatory_investigation security_incident security_hold
      fraud_investigation law_enforcement_request
    ].freeze

    include Core::AuditableModel

    belongs_to :event, class_name: "Events::Event", optional: true
    belongs_to :registration, class_name: "Ticketing::Registration", optional: true
    belongs_to :user, class_name: "Core::User", optional: true
    belongs_to :placed_by, class_name: "Core::User"
    belongs_to :released_by, class_name: "Core::User", optional: true

    validates :category, inclusion: { in: CATEGORIES }, allow_nil: true
    validates :reason_code, presence: true, inclusion: { in: REASON_CODES }
    validates :starts_at, presence: true
    validates :idempotency_key, presence: true, uniqueness: true

    validate :exactly_one_scope
    validate :release_fields_match
    validate :release_window

    scope :active, lambda {
      where(released_at: nil)
        .where("starts_at <= ?", Time.current)
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
    }

    def active?
      released_at.blank? && starts_at.present? && starts_at <= Time.current &&
        (expires_at.blank? || expires_at > Time.current)
    end

    def released?
      released_at.present?
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id registration_id user_id category reason_code placed_by_id starts_at expires_at
        released_by_id released_at idempotency_key created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event registration user placed_by released_by]
    end

    private

    def exactly_one_scope
      scope_count = [ event_id, registration_id, user_id ].compact.length
      return if scope_count == 1

      errors.add(:base, :invalid)
    end

    def release_fields_match
      return if released_at.blank? && released_by_id.blank?
      return if released_at.present? && released_by_id.present?

      errors.add(:base, :invalid)
    end

    def release_window
      if starts_at.present? && expires_at.present? && expires_at <= starts_at
        errors.add(:expires_at, :invalid)
      end

      return unless released_at.present? && starts_at.present? && released_at < starts_at

      errors.add(:released_at, :invalid)
    end
  end
end
