# frozen_string_literal: true

class CreateTicketingInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_invitations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_type_id, null: false
      t.uuid :invited_user_id
      t.string :name
      t.text :email_ciphertext
      t.text :phone_ciphertext
      t.text :token_ciphertext, null: false
      t.string :contact_digest, null: false
      t.string :token_digest, null: false
      t.string :idempotency_key_digest, limit: 64
      t.string :creation_request_digest, limit: 64
      t.integer :allowed_quantity, null: false, default: 1
      t.string :status, null: false, default: "pending"
      t.timestamptz :expires_at
      t.timestamptz :accepted_at
      t.uuid :created_by_id, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_invitations,
      "status IN ('pending','accepted','revoked','expired')",
      name: "ticketing_invitations_status_check"
    add_check_constraint :ticketing_invitations,
      "allowed_quantity >= 1",
      name: "ticketing_invitations_allowed_quantity_check"
    add_check_constraint :ticketing_invitations,
      "(idempotency_key_digest IS NULL AND creation_request_digest IS NULL) OR " \
      "(idempotency_key_digest ~ '^[0-9a-f]{64}$' AND creation_request_digest ~ '^[0-9a-f]{64}$')",
      name: "ticketing_invitations_idempotency_digests_check"

    add_index :ticketing_invitations, :token_digest, unique: true
    add_index :ticketing_invitations, %i[ticket_type_id contact_digest]
    add_index :ticketing_invitations, %i[ticket_type_id idempotency_key_digest],
              unique: true,
              where: "idempotency_key_digest IS NOT NULL",
              name: "idx_ticketing_invitations_on_ticket_type_and_idempotency"
    add_foreign_key :ticketing_invitations, :ticketing_ticket_types, column: :ticket_type_id
    add_foreign_key :ticketing_invitations, :core_users, column: :invited_user_id
    add_foreign_key :ticketing_invitations, :core_users, column: :created_by_id
  end
end
