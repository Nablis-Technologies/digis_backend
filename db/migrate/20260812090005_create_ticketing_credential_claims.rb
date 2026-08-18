# frozen_string_literal: true

class CreateTicketingCredentialClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_credential_claims, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :credential_id, null: false
      t.uuid :invited_user_id
      t.uuid :claimed_by_user_id
      t.string :contact_digest, limit: 64, null: false
      t.string :token_digest, limit: 64, null: false
      t.string :status, null: false, default: "pending"
      t.timestamptz :expires_at
      t.timestamptz :accepted_at

      t.timestamps
    end

    add_check_constraint :ticketing_credential_claims,
      "status IN ('pending','accepted','revoked','expired')",
      name: "ticketing_credential_claims_status_check"
    add_check_constraint :ticketing_credential_claims,
      "contact_digest ~ '^[0-9a-f]{64}$' AND token_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_credential_claims_digest_check"
    add_check_constraint :ticketing_credential_claims,
      "status <> 'accepted' OR (claimed_by_user_id IS NOT NULL AND accepted_at IS NOT NULL)",
      name: "ticketing_credential_claims_acceptance_check"

    add_index :ticketing_credential_claims, :credential_id, unique: true
    add_index :ticketing_credential_claims, :token_digest, unique: true
    add_index :ticketing_credential_claims, %i[status expires_at]

    add_foreign_key :ticketing_credential_claims, :ticketing_credentials, column: :credential_id
    add_foreign_key :ticketing_credential_claims, :core_users, column: :invited_user_id
    add_foreign_key :ticketing_credential_claims, :core_users, column: :claimed_by_user_id
  end
end
