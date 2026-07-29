# frozen_string_literal: true

module Catalog
  class ProductInventory < Catalog::ApplicationRecord
    self.table_name = "catalog_product_inventories"

    belongs_to :event_product, class_name: "Catalog::EventProduct"
    belongs_to :event_date, class_name: "Events::EventDate", optional: true

    has_many :inventory_reservations, class_name: "Catalog::InventoryReservation",
             dependent: :destroy, inverse_of: :product_inventory

    validates :event_product, presence: true
    validates :capacity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :held_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :sold_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :total_within_capacity

    scope :available, -> { where("held_count + sold_count < capacity") }

    def available?
      held_count + sold_count < capacity
    end

    def available_quantity
      capacity - held_count - sold_count
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_product_id event_date_id capacity
        held_count sold_count lock_version
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_product event_date]
    end

    private

    def total_within_capacity
      return if capacity.blank? || held_count.blank? || sold_count.blank?
      return if held_count + sold_count <= capacity

      errors.add(:base, I18n.t("catalog.product_inventory.errors.total_exceeds_capacity"))
    end
  end
end
