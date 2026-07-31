# frozen_string_literal: true

module Catalog
  # Explicit zone grants for a venue or parking product access row.
  # Stream access never has zone mappings.
  class ProductAccessZone < Catalog::ApplicationRecord
    self.table_name = "catalog_product_access_zones"

    belongs_to :product_access, class_name: "Catalog::ProductAccess",
               inverse_of: :product_access_zones
    belongs_to :access_zone, class_name: "Events::AccessZone"

    validates :product_access, presence: true
    validates :access_zone, presence: true
    validates :access_zone_id, uniqueness: { scope: :product_access_id }
    validate :access_type_allows_zones
    validate :zone_belongs_to_product_event
    validate :zone_type_matches_access_type

    def self.ransackable_attributes(_auth_object = nil)
      %w[id product_access_id access_zone_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[product_access access_zone]
    end

    private

    def access_type_allows_zones
      return if product_access.blank?
      return if product_access.venue? || product_access.parking?

      errors.add(:product_access, "stream access cannot have zone mappings")
    end

    def zone_belongs_to_product_event
      return if access_zone.blank? || product_access.blank?
      return if access_zone.event_id == product_access.event_product.event_id

      errors.add(:access_zone, "must belong to the same event as the product")
    end

    def zone_type_matches_access_type
      return if access_zone.blank? || product_access.blank?
      return if access_zone.type == product_access.type

      errors.add(:access_zone, "zone type must match access type")
    end
  end
end
