# frozen_string_literal: true

class CreateTicketingScannerSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_scanner_sessions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :scanner_invitation_id, null: false
      t.uuid :scanner_device_assignment_id, null: false
      t.string :token_digest, limit: 64, null: false
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false
      t.timestamptz :expires_at, null: false
      t.timestamptz :revoked_at

      t.timestamps
    end

    add_check_constraint :ticketing_scanner_sessions,
      "token_digest ~ '^[0-9a-f]{64}$' AND idempotency_key_digest ~ '^[0-9a-f]{64}$' AND " \
        "request_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_scanner_sessions_digests_check"
    add_check_constraint :ticketing_scanner_sessions,
      "expires_at > created_at",
      name: "ticketing_scanner_sessions_expiry_check"

    add_index :ticketing_scanner_sessions, :token_digest, unique: true
    add_index :ticketing_scanner_sessions, :idempotency_key_digest, unique: true
    add_index :ticketing_scanner_sessions, :scanner_invitation_id
    add_index :ticketing_scanner_sessions, :expires_at
    add_index :ticketing_scanner_sessions, :scanner_device_assignment_id,
              unique: true,
              where: "revoked_at IS NULL",
              name: "idx_active_ticketing_scanner_session_assignment"

    add_foreign_key :ticketing_scanner_sessions, :ticketing_scanner_invitations,
                    column: :scanner_invitation_id
    add_foreign_key :ticketing_scanner_sessions, :ticketing_scanner_device_assignments,
                    column: :scanner_device_assignment_id
  end
end
