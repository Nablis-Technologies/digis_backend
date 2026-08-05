# frozen_string_literal: true

class CreateCatalogExchangeRates < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_exchange_rates, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :from_currency, null: false
      t.string :to_currency, null: false
      t.decimal :rate, precision: 24, scale: 12, null: false
      t.timestamptz :effective_from, null: false, default: -> { "now()" }
      t.timestamptz :effective_to
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_check_constraint :catalog_exchange_rates,
      "from_currency ~ '^[A-Z]{3}$'",
      name: "catalog_exchange_rates_from_currency_check"
    add_check_constraint :catalog_exchange_rates,
      "to_currency ~ '^[A-Z]{3}$'",
      name: "catalog_exchange_rates_to_currency_check"
    add_check_constraint :catalog_exchange_rates,
      "rate > 0",
      name: "catalog_exchange_rates_rate_positive_check"

    add_index :catalog_exchange_rates, %i[from_currency to_currency]
    add_index :catalog_exchange_rates, :active
  end
end
