# frozen_string_literal: true

module Marketing
  # A versioned, server-managed price and policy for one discovery surface.
  class PlacementOffer < Marketing::ApplicationRecord
    self.table_name = "marketing_placement_offers"

    SURFACES = %w[public_discovery].freeze
    CURRENCY = "ETB"
    MINIMUM_DURATION_SECONDS = 24.hours.to_i
    MAXIMUM_DURATION_SECONDS = 14.days.to_i

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
    validates :terms_version, length: { maximum: 32 }
    validates :minimum_duration_seconds,
      numericality: { only_integer: true, greater_than_or_equal_to: MINIMUM_DURATION_SECONDS }
    validates :maximum_duration_seconds,
      numericality: { only_integer: true, less_than_or_equal_to: MAXIMUM_DURATION_SECONDS }
    validates :active, inclusion: { in: [ true, false ] }
    validate :duration_bounds_are_ordered
    validate :active_window_is_ordered

    scope :active_at, ->(at) { where(active: true).where("starts_at <= ? AND ends_at > ?", at, at) }

    def purchasable_at?(at: Time.current)
      active? && starts_at <= at && ends_at > at
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id code version daily_rate_minor currency minimum_duration_seconds maximum_duration_seconds surface
         terms_version active starts_at ends_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[featured_placements]
    end

    private

    def normalize_fields
      self.code = code.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.surface = surface.to_s.strip.downcase.presence
      self.terms_version = terms_version.to_s.strip.presence
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
  end
end
