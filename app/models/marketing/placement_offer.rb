# frozen_string_literal: true

module Marketing
  # A versioned, server-managed price and policy for one discovery surface.
  class PlacementOffer < Marketing::ApplicationRecord
    self.table_name = "marketing_placement_offers"

    SURFACES = %w[public_discovery].freeze
    CURRENCY = "ETB"
    STATUSES = %w[draft active retired].freeze
    MINIMUM_DURATION_SECONDS = 24.hours.to_i
    MAXIMUM_DURATION_SECONDS = 14.days.to_i
    IMMUTABLE_ATTRIBUTES = %w[
      code version daily_rate_minor currency minimum_duration_seconds maximum_duration_seconds
      surface terms_version starts_at ends_at created_by_id idempotency_key_digest request_digest
    ].freeze

    belongs_to :created_by, class_name: "Core::User"
    belongs_to :activated_by, class_name: "Core::User", optional: true
    belongs_to :retired_by, class_name: "Core::User", optional: true
    has_many :featured_placements,
             class_name: "Marketing::FeaturedPlacement",
             inverse_of: :placement_offer,
             dependent: :restrict_with_exception

    before_validation :normalize_fields

    validates :code, :version, :daily_rate_minor, :currency, :minimum_duration_seconds,
      :maximum_duration_seconds, :surface, :terms_version, :starts_at, :ends_at, presence: true
    validates :code, uniqueness: { scope: :version }
    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :daily_rate_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, inclusion: { in: [ CURRENCY ] }
    validates :surface, inclusion: { in: SURFACES }
    validates :status, inclusion: { in: STATUSES }
    validates :terms_version, length: { maximum: 32 }
    validates :idempotency_key_digest, :request_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :minimum_duration_seconds,
      numericality: { only_integer: true, greater_than_or_equal_to: MINIMUM_DURATION_SECONDS }
    validates :maximum_duration_seconds,
      numericality: { only_integer: true, less_than_or_equal_to: MAXIMUM_DURATION_SECONDS }
    validate :duration_bounds_are_ordered
    validate :active_window_is_ordered
    validate :lifecycle_metadata
    validate :immutable_snapshot, on: :update

    scope :active_at, ->(at) { where(status: "active").where("starts_at <= ? AND ends_at > ?", at, at) }

    def active? = status == "active"

    def draft? = status == "draft"

    def retired? = status == "retired"

    def purchasable_at?(at: Time.current)
      active? && starts_at <= at && ends_at > at
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id code version daily_rate_minor currency minimum_duration_seconds maximum_duration_seconds surface
         terms_version status starts_at ends_at created_by_id activated_by_id retired_by_id activated_at retired_at
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[created_by activated_by retired_by featured_placements]
    end

    private

    def normalize_fields
      self.code = code.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.surface = surface.to_s.strip.downcase.presence
      self.terms_version = terms_version.to_s.strip.presence
      self.status = status.to_s.strip.downcase.presence
    end

    def duration_bounds_are_ordered
      return if minimum_duration_seconds.blank? || maximum_duration_seconds.blank?
      return if maximum_duration_seconds >= minimum_duration_seconds

      errors.add(:maximum_duration_seconds, :greater_than_or_equal_to, count: minimum_duration_seconds)
    end

    def active_window_is_ordered
      return if starts_at.blank? || ends_at.blank? || ends_at > starts_at

      errors.add(:ends_at, :greater_than, count: starts_at)
    end

    def lifecycle_metadata
      case status
      when "draft"
        errors.add(:activated_at, :present) if activated_at.present?
        errors.add(:activated_by, :present) if activated_by_id.present?
        errors.add(:retired_at, :present) if retired_at.present?
        errors.add(:retired_by, :present) if retired_by_id.present?
      when "active"
        errors.add(:activated_at, :blank) if activated_at.blank?
        errors.add(:activated_by, :blank) if activated_by_id.blank?
        errors.add(:retired_at, :present) if retired_at.present?
        errors.add(:retired_by, :present) if retired_by_id.present?
      when "retired"
        errors.add(:retired_at, :blank) if retired_at.blank?
        errors.add(:retired_by, :blank) if retired_by_id.blank?
        errors.add(:activated_at, :invalid) if activated_by_id.present? != activated_at.present?
      end
    end

    def immutable_snapshot
      IMMUTABLE_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end
  end
end
