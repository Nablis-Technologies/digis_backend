# frozen_string_literal: true

class CreateCatalogInventoryReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_inventory_reservations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :product_inventory_id, null: false
      t.uuid :registration_id
      t.uuid :order_item_id
      t.uuid :reservation_group_id, null: false
      t.integer :quantity, null: false
      t.integer :admissions_per_unit, null: false, default: 1
      t.string :status, null: false, default: "held"
      t.timestamptz :expires_at
      t.timestamptz :committed_at
      t.timestamptz :released_at
      t.string :request_fingerprint, limit: 64, null: false

      t.timestamps
    end

    add_foreign_key :catalog_inventory_reservations, :catalog_product_inventories,
                    column: :product_inventory_id

    add_check_constraint :catalog_inventory_reservations,
      "quantity > 0",
      name: "catalog_inventory_reservations_quantity_check"
    add_check_constraint :catalog_inventory_reservations,
      "admissions_per_unit >= 1",
      name: "catalog_inventory_reservations_admissions_check"
    add_check_constraint :catalog_inventory_reservations,
      "status IN ('held','processing','committed','released','expired')",
      name: "catalog_inventory_reservations_status_check"
    add_check_constraint :catalog_inventory_reservations,
      "NOT (registration_id IS NOT NULL AND order_item_id IS NOT NULL)",
      name: "catalog_inventory_reservations_owner_check"
    add_check_constraint :catalog_inventory_reservations,
      "request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "catalog_inventory_reservations_fingerprint_check"
    add_check_constraint :catalog_inventory_reservations,
      "status IN ('committed','released','expired') OR expires_at IS NOT NULL",
      name: "catalog_inventory_reservations_expiry_check"

    add_index :catalog_inventory_reservations, :product_inventory_id
    add_index :catalog_inventory_reservations, :registration_id
    add_index :catalog_inventory_reservations, :order_item_id
    add_index :catalog_inventory_reservations, :reservation_group_id
    add_index :catalog_inventory_reservations, %i[reservation_group_id product_inventory_id],
              unique: true,
              name: "idx_inv_reservations_group_product_unique"
    add_index :catalog_inventory_reservations, %i[status expires_at],
              name: "idx_inventory_reservations_on_status_and_expires"
  end
end
