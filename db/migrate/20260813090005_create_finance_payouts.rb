# frozen_string_literal: true

class CreateFinancePayouts < ActiveRecord::Migration[8.1]
  def change
    create_table :finance_payouts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.string :currency, limit: 3, null: false
      t.string :status, null: false, default: "pending"
      t.bigint :amount_minor, null: false
      t.string :provider
      t.string :provider_reference
      t.string :idempotency_key, null: false
      t.timestamptz :period_start
      t.timestamptz :period_end
      t.timestamptz :requested_at, null: false
      t.timestamptz :paid_at
      t.string :failure_code
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :finance_payouts, :idempotency_key, unique: true,
              name: "idx_finance_payouts_on_idempotency_key"
    add_index :finance_payouts, %i[provider provider_reference], unique: true,
              where: "provider_reference IS NOT NULL",
              name: "idx_finance_payouts_on_provider_and_reference"
    add_index :finance_payouts, %i[organization_id currency status requested_at],
              name: "idx_finance_payouts_on_scope_and_status"

    add_check_constraint :finance_payouts,
      "currency ~ '^[A-Z]{3}$'",
      name: "finance_payouts_currency_check"
    add_check_constraint :finance_payouts,
      "status IN ('pending','processing','paid','failed','cancelled')",
      name: "finance_payouts_status_check"
    add_check_constraint :finance_payouts,
      "amount_minor > 0",
      name: "finance_payouts_positive_amount_check"
    add_check_constraint :finance_payouts,
      "lock_version >= 0",
      name: "finance_payouts_lock_version_check"

    add_foreign_key :finance_payouts, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
  end
end
