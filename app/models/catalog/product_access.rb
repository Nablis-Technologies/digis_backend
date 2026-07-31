# frozen_string_literal: true

module Catalog
  # Describes what a credential-bearing product grants — venue entry, stream
  # access, or parking. Each row is keyed by (product, event_date, type).
  # Rows become immutable once the first inventory reservation exists for the
  # product. Stream rows require `required_access_protection`; venue and
  # parking rows must leave it null.
  class ProductAccess < Catalog::ApplicationRecord
    self.table_name = "catalog_product_accesses"
    self.inheritance_column = nil

    ACCESS_TYPES = %w[venue stream parking].freeze
    PROTECTION_LEVELS = %w[public soft_gated signed].freeze

    belongs_to :event_product, class_name: "Catalog::EventProduct",
               inverse_of: :product_accesses
    belongs_to :event_date, class_name: "Events::EventDate",
               inverse_of: :product_accesses
    has_many :product_access_zones,
             class_name: "Catalog::ProductAccessZone",
             inverse_of: :product_access,
             dependent: :destroy

    validates :event_product, presence: true
    validates :event_date, presence: true
    validates :type, presence: true, inclusion: { in: ACCESS_TYPES }
    validates :event_date_id, uniqueness: { scope: %i[event_product_id type] }
    validates :usage_limit,
              numericality: { only_integer: true, greater_than: 0 },
              allow_nil: true
    validates :required_access_protection,
              inclusion: { in: PROTECTION_LEVELS },
              allow_nil: true
    validate :event_date_belongs_to_product_event
    validate :stream_protection_required
    validate :non_stream_protection_must_be_blank

    scope :for_product, ->(product) { where(event_product: product) }
    scope :by_type, ->(type) { where(type: type) }

    def venue?
      type == "venue"
    end

    def stream?
      type == "stream"
    end

    def parking?
      type == "parking"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_product_id event_date_id type required_access_protection
         usage_limit opens_offset_seconds closes_offset_seconds
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_product event_date product_access_zones]
    end

    private

    def event_date_belongs_to_product_event
      return if event_product.blank? || event_date.blank?
      return if event_product.event_id == event_date.event_id

      errors.add(:event_date, "must belong to the same event as the product")
    end

    def stream_protection_required
      return unless type == "stream" && required_access_protection.blank?

      errors.add(:required_access_protection, "must be set for stream access")
    end

    def non_stream_protection_must_be_blank
      return unless type != "stream" && required_access_protection.present?

      errors.add(:required_access_protection, "must be blank for non-stream access")
    end
  end
end
