# frozen_string_literal: true

class CreateCatalogProductAccesses < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_product_accesses, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_product_id, null: false
      t.uuid :event_date_id, null: false
      t.string :type, null: false
      t.string :required_access_protection
      t.integer :usage_limit
      t.integer :opens_offset_seconds
      t.integer :closes_offset_seconds

      t.timestamps
    end

    add_foreign_key :catalog_product_accesses, :catalog_event_products,
                    column: :event_product_id
    add_foreign_key :catalog_product_accesses, :events_event_dates,
                    column: :event_date_id

    add_check_constraint :catalog_product_accesses,
      "type IN ('venue','stream','parking')",
      name: "catalog_product_accesses_type_check"
    add_check_constraint :catalog_product_accesses,
      "required_access_protection IS NULL AND type <> 'stream' OR " \
      "required_access_protection IS NOT NULL AND type = 'stream'",
      name: "catalog_product_accesses_protection_stream_check"
    add_check_constraint :catalog_product_accesses,
      "required_access_protection IS NULL OR " \
      "required_access_protection IN ('public','soft_gated','signed')",
      name: "catalog_product_accesses_protection_check"
    add_check_constraint :catalog_product_accesses,
      "usage_limit > 0 OR usage_limit IS NULL",
      name: "catalog_product_accesses_usage_limit_check"
    add_check_constraint :catalog_product_accesses,
      "opens_offset_seconds IS NULL OR closes_offset_seconds IS NULL OR " \
      "(closes_offset_seconds - opens_offset_seconds) > 0",
      name: "catalog_product_accesses_offset_check"

    add_index :catalog_product_accesses,
              %i[event_product_id event_date_id type],
              unique: true,
              name: "idx_product_accesses_on_product_date_type"
    add_index :catalog_product_accesses, :event_date_id
  end
end
