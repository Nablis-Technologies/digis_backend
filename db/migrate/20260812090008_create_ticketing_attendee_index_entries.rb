# frozen_string_literal: true

class CreateTicketingAttendeeIndexEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_attendee_index_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.string :lookup_code, limit: 8, null: false
      t.string :phone_hash, limit: 64
      t.string :owner_phone_hash, limit: 64
      t.text :holder_name
      t.uuid :credential_id, null: false
      t.uuid :ticket_id, null: false
      t.integer :slot_positions, limit: 2, array: true, null: false, default: []
      t.string :credential_mode, null: false
      t.integer :generation_version, null: false
      t.integer :entry_limit, limit: 2, null: false
      t.string :ticket_type, null: false
      t.string :ticket_type_label
      t.jsonb :perks, null: false, default: []
      t.uuid :product_access_ids, array: true, null: false, default: []
      t.string :entry_validation_mode, null: false, default: "qr"
      t.bigint :index_version, null: false, default: 0
      t.boolean :removed, null: false, default: false

      t.timestamps
    end

    add_check_constraint :ticketing_attendee_index_entries,
      "cardinality(slot_positions) > 0 AND entry_limit = cardinality(slot_positions) AND " \
        "entry_limit > 0 AND generation_version > 0 AND index_version >= 0",
      name: "ticketing_attendee_index_entries_shape_check"
    add_check_constraint :ticketing_attendee_index_entries,
      "credential_mode IN ('group','delegated')",
      name: "ticketing_attendee_index_entries_mode_check"
    add_check_constraint :ticketing_attendee_index_entries,
      "entry_validation_mode IN ('qr','qr_and_id')",
      name: "ticketing_attendee_index_entries_validation_mode_check"
    add_check_constraint :ticketing_attendee_index_entries,
      "phone_hash IS NULL OR phone_hash ~ '^[0-9a-f]{64}$'",
      name: "ticketing_attendee_index_entries_phone_hash_check"
    add_check_constraint :ticketing_attendee_index_entries,
      "owner_phone_hash IS NULL OR owner_phone_hash ~ '^[0-9a-f]{64}$'",
      name: "ticketing_attendee_index_entries_owner_phone_hash_check"

    add_index :ticketing_attendee_index_entries, %i[event_id lookup_code], unique: true
    add_index :ticketing_attendee_index_entries, :credential_id, unique: true
    add_index :ticketing_attendee_index_entries, :phone_hash
    add_index :ticketing_attendee_index_entries, :owner_phone_hash
    add_index :ticketing_attendee_index_entries, %i[event_id index_version]
    add_index :ticketing_attendee_index_entries, :ticket_id

    add_foreign_key :ticketing_attendee_index_entries, :events_events, column: :event_id
    add_foreign_key :ticketing_attendee_index_entries, :ticketing_credentials,
      column: :credential_id
    add_foreign_key :ticketing_attendee_index_entries, :ticketing_tickets, column: :ticket_id
  end
end
