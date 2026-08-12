# frozen_string_literal: true

class CreateTicketingCredentialGenerations < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_credential_generations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_id, null: false
      t.integer :version, null: false
      t.string :mode, null: false
      t.string :status, null: false, default: "active"
      t.timestamptz :activated_at, null: false
      t.timestamptz :revoked_at
      t.string :revocation_reason

      t.timestamps
    end

    add_check_constraint :ticketing_credential_generations,
      "version > 0",
      name: "ticketing_credential_generations_version_check"
    add_check_constraint :ticketing_credential_generations,
      "mode IN ('group','delegated')",
      name: "ticketing_credential_generations_mode_check"
    add_check_constraint :ticketing_credential_generations,
      "status IN ('active','revoked')",
      name: "ticketing_credential_generations_status_check"
    add_check_constraint :ticketing_credential_generations,
      "(status = 'active' AND revoked_at IS NULL) OR " \
        "(status = 'revoked' AND revoked_at IS NOT NULL)",
      name: "ticketing_credential_generations_revocation_check"

    add_index :ticketing_credential_generations, %i[ticket_id version], unique: true
    add_index :ticketing_credential_generations, :ticket_id,
      unique: true,
      where: "status = 'active'",
      name: "idx_one_active_generation_per_ticket"

    add_foreign_key :ticketing_credential_generations, :ticketing_tickets, column: :ticket_id
  end
end
