# frozen_string_literal: true

class CreateMessagingCreditReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_credit_reservations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :credit_account_id, null: false
      t.uuid :organization_id, null: false
      t.uuid :rate_version_id, null: false
      t.string :source_type
      t.uuid :source_id
      t.string :channel, null: false
      t.bigint :quantity, null: false
      t.string :status, null: false, default: "reserved"
      t.string :idempotency_key_digest, limit: 64, null: false
      t.timestamptz :reserved_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :resolved_at
      t.string :resolution_code

      t.timestamps
    end

    add_check_constraint :messaging_credit_reservations,
      "channel IN ('sms','email')",
      name: "messaging_credit_reservations_channel_check"
    add_check_constraint :messaging_credit_reservations,
      "quantity > 0",
      name: "messaging_credit_reservations_quantity_check"
    add_check_constraint :messaging_credit_reservations,
      "status IN ('reserved','consumed','released','refunded','expired')",
      name: "messaging_credit_reservations_status_check"
    add_check_constraint :messaging_credit_reservations,
      "source_type IS NULL OR source_type IN ('Messaging::CampaignRecipient')",
      name: "messaging_credit_reservations_source_type_check"
    add_check_constraint :messaging_credit_reservations,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_credit_reservations_idempotency_check"
    add_check_constraint :messaging_credit_reservations,
      "(status = 'reserved' AND resolved_at IS NULL) OR (status <> 'reserved' AND resolved_at IS NOT NULL)",
      name: "messaging_credit_reservations_resolution_check"
    add_check_constraint :messaging_credit_reservations,
      "source_type IS NULL = (source_id IS NULL)",
      name: "messaging_credit_reservations_source_pair_check"

    add_index :messaging_credit_reservations,
      %i[credit_account_id idempotency_key_digest],
      unique: true,
      name: "idx_messaging_credit_reservations_account_idempotency"
    add_index :messaging_credit_reservations,
      %i[source_type source_id channel],
      unique: true,
      where: "source_type IS NOT NULL AND source_id IS NOT NULL",
      name: "idx_messaging_credit_reservations_source_channel"
    add_index :messaging_credit_reservations,
      %i[credit_account_id status reserved_at],
      where: "status = 'reserved'",
      name: "idx_messaging_credit_reservations_active"

    add_foreign_key :messaging_credit_reservations, :messaging_credit_accounts,
      column: :credit_account_id, on_delete: :restrict
    add_foreign_key :messaging_credit_reservations, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :messaging_credit_reservations, :messaging_credit_rate_versions,
      column: :rate_version_id, on_delete: :restrict
  end
end
