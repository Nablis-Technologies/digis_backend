# frozen_string_literal: true

class CreateTicketingAccessCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_access_codes, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_type_id, null: false
      t.string :code_digest, null: false
      t.string :label
      t.integer :max_uses
      t.integer :used_count, null: false, default: 0
      t.integer :max_quantity_per_use, null: false, default: 1
      t.timestamptz :starts_at
      t.timestamptz :expires_at
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_check_constraint :ticketing_access_codes,
      "used_count >= 0",
      name: "ticketing_access_codes_used_count_check"
    add_check_constraint :ticketing_access_codes,
      "max_uses IS NULL OR max_uses >= 1",
      name: "ticketing_access_codes_max_uses_check"
    add_check_constraint :ticketing_access_codes,
      "max_quantity_per_use >= 1",
      name: "ticketing_access_codes_max_quantity_check"
    add_check_constraint :ticketing_access_codes,
      "expires_at IS NULL OR starts_at IS NULL OR expires_at > starts_at",
      name: "ticketing_access_codes_window_check"

    add_index :ticketing_access_codes, %i[ticket_type_id code_digest], unique: true
    add_foreign_key :ticketing_access_codes, :ticketing_ticket_types, column: :ticket_type_id
  end
end
