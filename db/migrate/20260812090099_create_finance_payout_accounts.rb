# frozen_string_literal: true

class CreateFinancePayoutAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :finance_payout_accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.string :type, null: false
      t.string :provider, null: false
      t.string :bank_slug, null: false
      t.text :account_number_ciphertext, null: false
      t.string :account_number_digest, limit: 64, null: false
      t.text :account_name_ciphertext
      t.text :account_label_ciphertext
      t.string :status, null: false, default: "pending_verification"
      t.string :verification_source
      t.uuid :verified_by_id
      t.boolean :is_default, null: false, default: false
      t.timestamptz :verified_at
      t.timestamptz :last_used_at
      t.timestamps
    end

    add_index :finance_payout_accounts, %i[organization_id provider account_number_digest],
              unique: true, name: "idx_finance_payout_accounts_on_scope_and_digest"
    add_index :finance_payout_accounts, :organization_id,
              unique: true, where: "is_default",
              name: "idx_finance_payout_accounts_on_default_organization"
    add_index :finance_payout_accounts, %i[organization_id status created_at],
              name: "idx_finance_payout_accounts_on_scope_status_created"

    add_check_constraint :finance_payout_accounts,
      "type IN ('bank','mobile_money')",
      name: "finance_payout_accounts_type_check"
    add_check_constraint :finance_payout_accounts,
      "provider IN ('chapa')",
      name: "finance_payout_accounts_provider_check"
    add_check_constraint :finance_payout_accounts,
      "bank_slug ~ '^[a-z0-9][a-z0-9_-]*$'",
      name: "finance_payout_accounts_bank_slug_check"
    add_check_constraint :finance_payout_accounts,
      "account_number_digest ~ '^[0-9a-f]{64}$'",
      name: "finance_payout_accounts_digest_check"
    add_check_constraint :finance_payout_accounts,
      "status IN ('pending_verification','verified','suspended','closed')",
      name: "finance_payout_accounts_status_check"
    add_check_constraint :finance_payout_accounts,
      "verification_source IS NULL OR verification_source IN ('provider','test_fixture','manual')",
      name: "finance_payout_accounts_verification_source_check"
    add_check_constraint :finance_payout_accounts,
      "((status = 'verified' AND verified_at IS NOT NULL AND verification_source IS NOT NULL AND " \
      "(verification_source <> 'manual' OR verified_by_id IS NOT NULL)) OR " \
      "(status <> 'verified' AND verified_at IS NULL AND verification_source IS NULL AND verified_by_id IS NULL))",
      name: "finance_payout_accounts_verification_metadata_check"
    add_check_constraint :finance_payout_accounts,
      "(NOT is_default OR status = 'verified')",
      name: "finance_payout_accounts_default_status_check"

    add_foreign_key :finance_payout_accounts, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :finance_payout_accounts, :core_users,
                    column: :verified_by_id, on_delete: :restrict
  end
end
