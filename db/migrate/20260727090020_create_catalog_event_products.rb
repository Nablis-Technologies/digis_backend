# frozen_string_literal: true

class CreateCatalogEventProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_event_products, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.string :name, null: false
      t.text :description
      t.string :type, null: false
      t.boolean :active, null: false, default: true
      t.boolean :hidden, null: false, default: false
      t.boolean :allow_custom_price, null: false, default: false
      t.timestamptz :sales_start_at
      t.timestamptz :sales_end_at
      t.integer :min_per_order, null: false, default: 1
      t.integer :max_per_order
      t.string :schedule_change_refund_policy, null: false, default: "full_or_partial"
      t.integer :sort_order, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_check_constraint :catalog_event_products,
      "type IN ('ticket','parking','merchandise','food','donation','digital_addon','other')",
      name: "catalog_event_products_type_check"
    add_check_constraint :catalog_event_products,
      "min_per_order >= 1",
      name: "catalog_event_products_min_per_order_check"
    add_check_constraint :catalog_event_products,
      "max_per_order IS NULL OR max_per_order >= min_per_order",
      name: "catalog_event_products_max_per_order_check"
    add_check_constraint :catalog_event_products,
      "sales_end_at IS NULL OR sales_start_at IS NULL OR sales_end_at > sales_start_at",
      name: "catalog_event_products_sales_window_check"
    add_check_constraint :catalog_event_products,
      "schedule_change_refund_policy IN ('full_or_partial','full_only')",
      name: "catalog_event_products_refund_policy_check"

    add_index :catalog_event_products, %i[event_id active sort_order]
    add_foreign_key :catalog_event_products, :events_events, column: :event_id
  end
end
