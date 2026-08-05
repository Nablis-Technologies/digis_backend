# frozen_string_literal: true

class CreateTicketingAccessCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_access_codes, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_type_id, null: false
      t.string :code_digest, null: false
      t.text :code_ciphertext
      t.string :idempotency_key_digest, limit: 64
      t.string :creation_request_digest, limit: 64
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
    add_check_constraint :ticketing_access_codes,
      "(idempotency_key_digest IS NULL AND creation_request_digest IS NULL) OR " \
      "(idempotency_key_digest ~ '^[0-9a-f]{64}$' AND creation_request_digest ~ '^[0-9a-f]{64}$')",
      name: "ticketing_access_codes_idempotency_digests_check"

    add_index :ticketing_access_codes, %i[ticket_type_id code_digest], unique: true
    add_index :ticketing_access_codes, %i[ticket_type_id idempotency_key_digest],
              unique: true,
              where: "idempotency_key_digest IS NOT NULL",
              name: "idx_ticketing_access_codes_on_ticket_type_and_idempotency"
    add_foreign_key :ticketing_access_codes, :ticketing_ticket_types, column: :ticket_type_id
  end
end
