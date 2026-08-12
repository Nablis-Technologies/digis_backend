# frozen_string_literal: true

class CreateTicketingCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_credentials, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_id, null: false
      t.uuid :credential_generation_id, null: false
      t.uuid :admission_slot_id
      t.uuid :event_id, null: false
      t.string :type, null: false
      t.uuid :holder_user_id
      t.text :holder_name
      t.string :status, null: false, default: "pending_claim"
      t.integer :slot_positions, limit: 2, array: true, null: false, default: []
      t.integer :entry_limit, limit: 2, null: false
      t.text :qr_token
      t.string :lookup_code, limit: 8
      t.timestamptz :issued_at
      t.timestamptz :revoked_at
      t.string :revocation_reason

      t.timestamps
    end

    add_check_constraint :ticketing_credentials,
      "type IN ('package','individual')",
      name: "ticketing_credentials_type_check"
    add_check_constraint :ticketing_credentials,
      "status IN ('pending_claim','pending_requirements','active','revoked')",
      name: "ticketing_credentials_status_check"
    add_check_constraint :ticketing_credentials,
      "cardinality(slot_positions) > 0 AND entry_limit = cardinality(slot_positions) AND " \
        "entry_limit > 0",
      name: "ticketing_credentials_slot_shape_check"
    add_check_constraint :ticketing_credentials,
      "(type = 'package' AND admission_slot_id IS NULL) OR " \
        "(type = 'individual' AND admission_slot_id IS NOT NULL AND entry_limit = 1)",
      name: "ticketing_credentials_admission_slot_check"
    add_check_constraint :ticketing_credentials,
      "(status IN ('pending_claim','pending_requirements') AND qr_token IS NULL AND " \
        "lookup_code IS NULL AND issued_at IS NULL) OR " \
        "(status = 'active' AND qr_token IS NOT NULL AND lookup_code IS NOT NULL AND issued_at IS NOT NULL) OR " \
        "status = 'revoked'",
      name: "ticketing_credentials_activation_check"
    add_check_constraint :ticketing_credentials,
      "(status = 'revoked' AND revoked_at IS NOT NULL) OR " \
        "(status <> 'revoked' AND revoked_at IS NULL)",
      name: "ticketing_credentials_revocation_check"

    add_index :ticketing_credentials, %i[event_id lookup_code],
      unique: true,
      where: "lookup_code IS NOT NULL",
      name: "idx_ticketing_credentials_event_lookup"
    add_index :ticketing_credentials, :credential_generation_id,
      unique: true,
      where: "type = 'package'",
      name: "idx_one_package_credential_per_generation"
    add_index :ticketing_credentials, %i[credential_generation_id admission_slot_id],
      unique: true,
      where: "type = 'individual'",
      name: "idx_one_individual_credential_per_slot"
    add_index :ticketing_credentials, %i[ticket_id status]

    add_foreign_key :ticketing_credentials, :ticketing_tickets, column: :ticket_id
    add_foreign_key :ticketing_credentials, :ticketing_credential_generations,
      column: :credential_generation_id
    add_foreign_key :ticketing_credentials, :ticketing_admission_slots,
      column: :admission_slot_id
    add_foreign_key :ticketing_credentials, :events_events, column: :event_id
    add_foreign_key :ticketing_credentials, :core_users, column: :holder_user_id
  end
end
