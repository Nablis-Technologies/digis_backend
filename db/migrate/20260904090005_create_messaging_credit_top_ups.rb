# frozen_string_literal: true

class CreateMessagingCreditTopUps < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_credit_top_ups, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :credit_account_id, null: false
      t.uuid :rate_version_id, null: false
      t.uuid :orders_billing_purchase_id
      t.uuid :accepted_payment_id
      t.string :channel, null: false
      t.bigint :quantity, null: false
      t.string :currency, limit: 3, null: false
      t.bigint :amount_minor, null: false
      t.string :price_digest, limit: 64, null: false
      t.string :status, null: false, default: "created"
      t.string :provider_reference
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false

      t.timestamps
    end

    add_check_constraint :messaging_credit_top_ups,
      "channel IN ('sms','email')",
      name: "messaging_credit_top_ups_channel_check"
    add_check_constraint :messaging_credit_top_ups,
      "quantity > 0 AND amount_minor > 0",
      name: "messaging_credit_top_ups_amount_check"
    add_check_constraint :messaging_credit_top_ups,
      "currency ~ '^[A-Z]{3}$' AND price_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_credit_top_ups_snapshot_check"
    add_check_constraint :messaging_credit_top_ups,
      "status IN ('created','pending_payment','paid','cancelled','failed','reversed')",
      name: "messaging_credit_top_ups_status_check"
    add_check_constraint :messaging_credit_top_ups,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_credit_top_ups_idempotency_check"
    add_check_constraint :messaging_credit_top_ups,
      "request_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_credit_top_ups_request_check"

    add_index :messaging_credit_top_ups,
      %i[organization_id idempotency_key_digest],
      unique: true,
      name: "idx_messaging_credit_top_ups_organization_idempotency"
    add_index :messaging_credit_top_ups, %i[credit_account_id status created_at],
      name: "idx_messaging_credit_top_ups_account_status"
    add_index :messaging_credit_top_ups, :orders_billing_purchase_id,
      unique: true,
      where: "orders_billing_purchase_id IS NOT NULL",
      name: "idx_messaging_credit_top_ups_billing_purchase"

    add_foreign_key :messaging_credit_top_ups, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :messaging_credit_top_ups, :messaging_credit_accounts,
      column: :credit_account_id, on_delete: :restrict
    add_foreign_key :messaging_credit_top_ups, :messaging_credit_rate_versions,
      column: :rate_version_id, on_delete: :restrict
    add_foreign_key :messaging_credit_top_ups, :orders_billing_purchases,
      column: :orders_billing_purchase_id, on_delete: :restrict
    add_foreign_key :messaging_credit_top_ups, :orders_payments,
      column: :accepted_payment_id, on_delete: :restrict
  end
end
