# frozen_string_literal: true

class CreateMarketplaceSellerPayoutAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_seller_payout_accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :user_id, null: false
      t.string :type, null: false
      t.string :provider, null: false
      t.string :bank_slug, null: false
      t.text :account_number_ciphertext, null: false
      t.string :account_number_digest, limit: 64, null: false
      t.text :account_label_ciphertext
      t.text :holder_name_ciphertext, null: false
      t.string :verification_source
      t.uuid :verified_by_id
      t.boolean :is_default, null: false, default: false
      t.string :status, null: false, default: "pending_verification"
      t.timestamptz :verified_at
      t.timestamptz :last_used_at

      t.timestamps
    end

    add_index :marketplace_seller_payout_accounts, %i[user_id provider account_number_digest], unique: true,
              name: "idx_marketplace_payout_accounts_on_user_provider_account_digest"
    add_index :marketplace_seller_payout_accounts, %i[user_id status],
              name: "idx_marketplace_payout_accounts_on_user_and_status"
    add_index :marketplace_seller_payout_accounts, %i[user_id provider], unique: true, where: "is_default",
              name: "idx_marketplace_payout_accounts_on_default_user_provider"

    add_check_constraint :marketplace_seller_payout_accounts,
      "type IN ('bank')",
      name: "marketplace_payout_accounts_type_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "provider IN ('chapa')",
      name: "marketplace_payout_accounts_provider_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "bank_slug ~ '^[a-z0-9][a-z0-9_-]*$'",
      name: "marketplace_payout_accounts_bank_slug_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "account_number_digest ~ '^[0-9a-f]{64}$'",
      name: "marketplace_payout_accounts_digest_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "status IN ('pending_verification','verified','suspended','closed')",
      name: "marketplace_payout_accounts_status_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "verification_source IS NULL OR verification_source IN ('provider','test_fixture','manual')",
      name: "marketplace_payout_accounts_verification_source_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "((status = 'verified' AND verified_at IS NOT NULL AND verification_source IS NOT NULL AND " \
      "(verification_source <> 'manual' OR verified_by_id IS NOT NULL)) OR " \
      "(status <> 'verified' AND verified_at IS NULL AND verification_source IS NULL AND verified_by_id IS NULL))",
      name: "marketplace_payout_accounts_verification_metadata_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "(NOT is_default OR status = 'verified')",
      name: "marketplace_payout_accounts_default_status_check"

    add_foreign_key :marketplace_seller_payout_accounts, :core_users,
                    column: :user_id, on_delete: :restrict
    add_foreign_key :marketplace_seller_payout_accounts, :core_users,
                    column: :verified_by_id, on_delete: :restrict
  end
end
