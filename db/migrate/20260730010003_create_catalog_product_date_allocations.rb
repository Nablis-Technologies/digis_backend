# frozen_string_literal: true

class CreateCatalogProductDateAllocations < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_product_date_allocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_product_id, null: false
      t.uuid :event_date_id, null: false
      t.integer :allocation_basis_points, null: false

      t.timestamps
    end

    add_foreign_key :catalog_product_date_allocations, :catalog_event_products,
                    column: :event_product_id
    add_foreign_key :catalog_product_date_allocations, :events_event_dates,
                    column: :event_date_id

    add_check_constraint :catalog_product_date_allocations,
      "allocation_basis_points > 0 AND allocation_basis_points <= 10000",
      name: "catalog_product_date_allocations_bps_range_check"

    add_index :catalog_product_date_allocations,
              %i[event_product_id event_date_id],
              unique: true,
              name: "idx_date_allocations_on_product_and_date"
  end
end
