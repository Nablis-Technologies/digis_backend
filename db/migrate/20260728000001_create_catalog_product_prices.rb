# frozen_string_literal: true

class CreateCatalogProductPrices < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    enable_extension :btree_gist

    create_table :catalog_product_prices, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_product_id, null: false
      t.uuid :ticket_type_id
      t.string :currency, null: false
      t.bigint :amount_minor, null: false
      t.string :kind, null: false, default: "base"
      t.timestamptz :active_from, null: false
      t.timestamptz :active_to
      t.tstzrange :active_range, null: false,
        as: "tstzrange(active_from, active_to, '[]')", stored: true

      t.timestamps
    end

    add_check_constraint :catalog_product_prices,
      "currency ~ '^[A-Z]{3}$'",
      name: "catalog_product_prices_currency_check"
    add_check_constraint :catalog_product_prices,
      "kind IN ('base','override')",
      name: "catalog_product_prices_kind_check"
    add_check_constraint :catalog_product_prices,
      "amount_minor >= 0",
      name: "catalog_product_prices_amount_check"

    add_index :catalog_product_prices, :event_product_id
    add_index :catalog_product_prices, :ticket_type_id
    add_index :catalog_product_prices, :currency
    add_foreign_key :catalog_product_prices, :catalog_event_products, column: :event_product_id
    add_foreign_key :catalog_product_prices, :ticketing_ticket_types, column: :ticket_type_id

    reversible do |dir|
      dir.up do
        execute <<~SQL
          ALTER TABLE catalog_product_prices
            ADD CONSTRAINT catalog_product_prices_active_range_excl
            EXCLUDE USING gist (
              event_product_id WITH =,
              coalesce(ticket_type_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
              currency WITH =,
              active_range WITH &&
            )
        SQL
      end
      dir.down do
        execute "ALTER TABLE catalog_product_prices DROP CONSTRAINT IF EXISTS catalog_product_prices_active_range_excl"
      end
    end
  end
end
