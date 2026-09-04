# frozen_string_literal: true

class CreateOrdersBillingPurchases < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_billing_purchases, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :requested_by_id, null: false
      t.string :kind, null: false
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.string :currency, limit: 3, null: false
      t.bigint :amount_minor, null: false
      t.string :price_digest, limit: 64, null: false
      t.string :status, null: false, default: "created"
      t.string :provider_reference
      t.string :idempotency_key_digest, limit: 64, null: false
      t.timestamptz :expires_at, null: false

      t.timestamps
    end

    add_check_constraint :orders_billing_purchases,
      "kind IN ('messaging_credit_top_up')",
      name: "orders_billing_purchases_kind_check"
    add_check_constraint :orders_billing_purchases,
      "source_type IN ('Messaging::CreditTopUp')",
      name: "orders_billing_purchases_source_type_check"
    add_check_constraint :orders_billing_purchases,
      "currency ~ '^[A-Z]{3}$' AND amount_minor > 0 AND price_digest ~ '^[0-9a-f]{64}$'",
      name: "orders_billing_purchases_snapshot_check"
    add_check_constraint :orders_billing_purchases,
      "status IN ('created','pending_payment','paid','cancelled','failed','reversed')",
      name: "orders_billing_purchases_status_check"
    add_check_constraint :orders_billing_purchases,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "orders_billing_purchases_idempotency_check"
    add_check_constraint :orders_billing_purchases,
      "btrim(source_id::text) <> ''",
      name: "orders_billing_purchases_source_check"

    add_index :orders_billing_purchases, %i[organization_id idempotency_key_digest],
      unique: true,
      name: "idx_orders_billing_purchases_organization_idempotency"
    add_index :orders_billing_purchases, %i[source_type source_id],
      unique: true,
      name: "idx_orders_billing_purchases_source"
    add_index :orders_billing_purchases, %i[status expires_at],
      name: "idx_orders_billing_purchases_status_expiry"

    add_foreign_key :orders_billing_purchases, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :orders_billing_purchases, :core_users,
      column: :requested_by_id, on_delete: :restrict
  end
end
