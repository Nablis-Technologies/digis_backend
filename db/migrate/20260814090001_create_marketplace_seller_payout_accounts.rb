# frozen_string_literal: true

class CreateMarketplaceSellerPayoutAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_seller_payout_accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :user_id, null: false
      t.string :type, null: false
      t.string :provider, null: false
      # Provider token only. Raw account credentials are never stored here.
      t.string :account_token, null: false
      t.text :account_label_ciphertext
      t.text :holder_name_ciphertext, null: false
      t.string :status, null: false, default: "pending_verification"
      t.timestamptz :verified_at
      t.timestamptz :last_used_at

      t.timestamps
    end

    add_index :marketplace_seller_payout_accounts, %i[provider account_token], unique: true,
              name: "idx_marketplace_payout_accounts_on_provider_and_token"
    add_index :marketplace_seller_payout_accounts, %i[user_id status],
              name: "idx_marketplace_payout_accounts_on_user_and_status"

    add_check_constraint :marketplace_seller_payout_accounts,
      "type IN ('mobile_money','bank')",
      name: "marketplace_payout_accounts_type_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "provider IN ('telebirr','chapa','bank')",
      name: "marketplace_payout_accounts_provider_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "status IN ('pending_verification','verified','suspended','closed')",
      name: "marketplace_payout_accounts_status_check"
    add_check_constraint :marketplace_seller_payout_accounts,
      "((status = 'verified' AND verified_at IS NOT NULL) OR " \
      "(status <> 'verified' AND verified_at IS NULL))",
      name: "marketplace_payout_accounts_verification_metadata_check"

    add_foreign_key :marketplace_seller_payout_accounts, :core_users,
                    column: :user_id, on_delete: :restrict
  end
end
