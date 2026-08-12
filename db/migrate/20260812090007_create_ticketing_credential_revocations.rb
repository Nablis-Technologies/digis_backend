# frozen_string_literal: true

class CreateTicketingCredentialRevocations < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_credential_revocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :credential_id, null: false
      t.string :reason, null: false
      t.timestamptz :revoked_at, null: false
      t.bigint :revocation_version, null: false, default: 0

      t.timestamps
    end

    add_check_constraint :ticketing_credential_revocations,
      "revocation_version >= 0 AND reason <> ''",
      name: "ticketing_credential_revocations_values_check"

    add_index :ticketing_credential_revocations, :credential_id, unique: true
    add_index :ticketing_credential_revocations, %i[event_id revocation_version]

    add_foreign_key :ticketing_credential_revocations, :events_events, column: :event_id
    add_foreign_key :ticketing_credential_revocations, :ticketing_credentials,
      column: :credential_id
  end
end
