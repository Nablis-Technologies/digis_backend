# frozen_string_literal: true

class CreateTicketingRevocations < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_revocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :ticket_id, null: false
      t.integer :revoked_through_version, null: false, default: 0
      t.boolean :is_dead, null: false, default: false
      t.boolean :is_suspended, null: false, default: false
      t.bigint :revocation_version, null: false, default: 0

      t.timestamps
    end

    add_check_constraint :ticketing_revocations,
      "revoked_through_version >= 0 AND revocation_version >= 0",
      name: "ticketing_revocations_versions_check"

    add_index :ticketing_revocations, :ticket_id, unique: true
    add_index :ticketing_revocations, %i[event_id revocation_version]

    add_foreign_key :ticketing_revocations, :events_events, column: :event_id
    add_foreign_key :ticketing_revocations, :ticketing_tickets, column: :ticket_id
  end
end
