# frozen_string_literal: true

module Marketing
  # Versioned admission limits; public paid-placement serving uses this same
  # hard ceiling but never the mutable current policy value.
  class PlacementCapacityPolicy < Marketing::ApplicationRecord
    class AmbiguousActivePoliciesError < Core::Error; end

    self.table_name = "marketing_placement_capacity_policies"

    SURFACES = PlacementOffer::SURFACES
    STATUSES = %w[draft active retired].freeze
    MAX_CONCURRENT = 100
    IMMUTABLE_ATTRIBUTES = %w[
      surface version max_concurrent effective_from effective_until created_by_id
      idempotency_key_digest request_digest
    ].freeze

    belongs_to :created_by, class_name: "Core::User"
    belongs_to :activated_by, class_name: "Core::User", optional: true
    belongs_to :retired_by, class_name: "Core::User", optional: true

    before_validation :normalize_fields

    validates :surface, :version, :max_concurrent, :status, :effective_from, presence: true
    validates :surface, inclusion: { in: SURFACES }
    validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :surface }
    validates :max_concurrent,
      numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_CONCURRENT }
    validates :status, inclusion: { in: STATUSES }
    validates :idempotency_key_digest, :request_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validate :effective_window_is_ordered
    validate :lifecycle_metadata
    validate :immutable_policy, on: :update

    scope :active_at, ->(at) do
      where(status: "active")
        .where("effective_from <= ? AND (effective_until IS NULL OR effective_until > ?)", at, at)
    end

    def self.active_for(surface:, at: Time.current)
      policies = active_at(at.to_time.utc).where(surface: surface.to_s.strip.downcase).limit(2).to_a
      return if policies.empty?
      raise AmbiguousActivePoliciesError, "Multiple active capacity policies match one surface and instant" if policies.many?

      policies.first
    end

    def active? = status == "active"

    def draft? = status == "draft"

    def retired? = status == "retired"

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id surface version max_concurrent status effective_from effective_until
        created_by_id activated_by_id retired_by_id activated_at retired_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[created_by activated_by retired_by]
    end

    private

    def normalize_fields
      self.surface = surface.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
    end

    def effective_window_is_ordered
      return if effective_from.blank? || effective_until.blank? || effective_until > effective_from

      errors.add(:effective_until, :greater_than, count: effective_from)
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

    def immutable_policy
      IMMUTABLE_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end
  end
end
