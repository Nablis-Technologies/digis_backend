# frozen_string_literal: true

class CreateTicketingTicketTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_ticket_transfers, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_id, null: false
      t.uuid :from_user_id, null: false
      t.uuid :to_user_id, null: false
      t.uuid :initiated_by_id, null: false
      t.string :token_digest, limit: 64, null: false
      t.text :token_ciphertext, null: false
      t.string :status, null: false, default: "pending"
      t.integer :previous_version, null: false
      t.integer :new_version
      t.string :reason
      t.timestamptz :expires_at, null: false
      t.timestamptz :accepted_at
      t.timestamptz :declined_at
      t.timestamptz :cancelled_at

      t.timestamps
    end

    add_check_constraint :ticketing_ticket_transfers,
      "status IN ('pending','accepted','declined','cancelled','expired')",
      name: "ticketing_ticket_transfers_status_check"
    add_check_constraint :ticketing_ticket_transfers,
      "token_digest ~ '^[0-9a-f]{64}$' AND previous_version > 0",
      name: "ticketing_ticket_transfers_values_check"
    add_check_constraint :ticketing_ticket_transfers,
      "from_user_id <> to_user_id",
      name: "ticketing_ticket_transfers_recipient_check"
    add_check_constraint :ticketing_ticket_transfers,
      "(status = 'accepted' AND new_version IS NOT NULL AND accepted_at IS NOT NULL) OR " \
        "(status <> 'accepted' AND new_version IS NULL AND accepted_at IS NULL)",
      name: "ticketing_ticket_transfers_acceptance_check"
    add_check_constraint :ticketing_ticket_transfers,
      "(status = 'declined' AND declined_at IS NOT NULL) OR " \
        "(status <> 'declined' AND declined_at IS NULL)",
      name: "ticketing_ticket_transfers_decline_check"
    add_check_constraint :ticketing_ticket_transfers,
      "(status = 'cancelled' AND cancelled_at IS NOT NULL) OR " \
        "(status <> 'cancelled' AND cancelled_at IS NULL)",
      name: "ticketing_ticket_transfers_cancellation_check"

    add_index :ticketing_ticket_transfers, :token_digest, unique: true
    add_index :ticketing_ticket_transfers, %i[status expires_at]
    add_index :ticketing_ticket_transfers, :ticket_id,
      unique: true,
      where: "status = 'pending'",
      name: "idx_one_pending_ticket_transfer"

    add_foreign_key :ticketing_ticket_transfers, :ticketing_tickets, column: :ticket_id
    add_foreign_key :ticketing_ticket_transfers, :core_users, column: :from_user_id
    add_foreign_key :ticketing_ticket_transfers, :core_users, column: :to_user_id
    add_foreign_key :ticketing_ticket_transfers, :core_users, column: :initiated_by_id
  end
end
