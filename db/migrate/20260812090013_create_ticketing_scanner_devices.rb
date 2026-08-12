# frozen_string_literal: true

class CreateTicketingScannerDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_scanner_devices, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.string :device_identifier, null: false
      t.string :name
      t.string :token_digest, limit: 64, null: false
      t.string :status, null: false, default: "active"
      t.timestamptz :last_seen_at
      t.timestamptz :revoked_at

      t.timestamps
    end

    add_check_constraint :ticketing_scanner_devices,
      "btrim(device_identifier) <> ''",
      name: "ticketing_scanner_devices_identifier_check"
    add_check_constraint :ticketing_scanner_devices,
      "token_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_scanner_devices_token_digest_check"
    add_check_constraint :ticketing_scanner_devices,
      "status IN ('active','suspended','revoked')",
      name: "ticketing_scanner_devices_status_check"

    add_index :ticketing_scanner_devices, :device_identifier, unique: true
    add_index :ticketing_scanner_devices, :token_digest, unique: true
    add_index :ticketing_scanner_devices, %i[organization_id status]

    add_foreign_key :ticketing_scanner_devices, :organizations_organizations,
                    column: :organization_id
  end
end
