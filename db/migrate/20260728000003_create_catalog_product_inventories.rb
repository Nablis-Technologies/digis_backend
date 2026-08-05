# frozen_string_literal: true

class CreateCatalogProductInventories < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_product_inventories, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_product_id, null: false
      t.uuid :event_date_id
      t.integer :capacity, null: false
      t.integer :held_count, null: false, default: 0
      t.integer :sold_count, null: false, default: 0
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_foreign_key :catalog_product_inventories, :catalog_event_products, column: :event_product_id
    add_foreign_key :catalog_product_inventories, :events_event_dates, column: :event_date_id

    add_check_constraint :catalog_product_inventories,
      "capacity >= 0",
      name: "catalog_product_inventories_capacity_check"
    add_check_constraint :catalog_product_inventories,
      "held_count >= 0",
      name: "catalog_product_inventories_held_count_check"
    add_check_constraint :catalog_product_inventories,
      "sold_count >= 0",
      name: "catalog_product_inventories_sold_count_check"
    add_check_constraint :catalog_product_inventories,
      "held_count + sold_count <= capacity",
      name: "catalog_product_inventories_total_check"

    add_index :catalog_product_inventories, :event_product_id
    add_index :catalog_product_inventories, :event_date_id

    add_index :catalog_product_inventories, %i[event_product_id event_date_id],
              unique: true,
              where: "event_date_id IS NOT NULL",
              name: "idx_inventories_on_product_and_date"
    add_index :catalog_product_inventories, :event_product_id,
              unique: true,
              where: "event_date_id IS NULL",
              name: "idx_inventories_on_product_where_date_null"
  end
end
