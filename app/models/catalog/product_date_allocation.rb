# frozen_string_literal: true

module Catalog
  # Defines how a multi-date product's value is divided across its covered
  # dates for schedule-change and date-cancellation refunds. Allocations for
  # one product must sum exactly to 10,000 basis points at commit.
  # Immutable after the first inventory reservation exists.
  class ProductDateAllocation < Catalog::ApplicationRecord
    self.table_name = "catalog_product_date_allocations"

    belongs_to :event_product, class_name: "Catalog::EventProduct",
               inverse_of: :product_date_allocations
    belongs_to :event_date, class_name: "Events::EventDate"

    validates :event_product, presence: true
    validates :event_date, presence: true
    validates :event_date_id, uniqueness: { scope: :event_product_id }
    validates :allocation_basis_points,
              presence: true,
              numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 10_000 }
    validate :event_date_belongs_to_product_event

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_product_id event_date_id allocation_basis_points
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_product event_date]
    end

    private

    def event_date_belongs_to_product_event
      return if event_product.blank? || event_date.blank?
      return if event_product.event_id == event_date.event_id

       errors.add(:event_date, I18n.t("catalog.product_date_allocation.errors.event_date_event_mismatch"))
    end
  end
end
