# frozen_string_literal: true

class CreateMarketplaceSellerPayouts < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_seller_payouts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :seller_user_id, null: false
      t.uuid :seller_payout_account_id, null: false
      t.string :provider, null: false
      t.string :provider_reference
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.string :status, null: false, default: "pending"
      t.string :idempotency_key, null: false
      t.timestamptz :requested_at, null: false
      t.timestamptz :processed_at
      t.string :failure_code
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :marketplace_seller_payouts, :idempotency_key,
              unique: true,
              name: "idx_marketplace_seller_payouts_on_idempotency_key"
    add_index :marketplace_seller_payouts, %i[provider provider_reference],
              unique: true,
              where: "provider_reference IS NOT NULL",
              name: "idx_marketplace_seller_payouts_on_provider_reference"
    add_index :marketplace_seller_payouts, %i[seller_user_id status requested_at],
              name: "idx_marketplace_seller_payouts_on_seller_status_requested"

    add_check_constraint :marketplace_seller_payouts,
      "provider IN ('telebirr','chapa','bank')",
      name: "marketplace_seller_payouts_provider_check"
    add_check_constraint :marketplace_seller_payouts,
      "amount_minor > 0 AND lock_version >= 0",
      name: "marketplace_seller_payouts_positive_amount_check"
    add_check_constraint :marketplace_seller_payouts,
      "currency ~ '^[A-Z]{3}$'",
      name: "marketplace_seller_payouts_currency_check"
    add_check_constraint :marketplace_seller_payouts,
      "status IN ('pending','processing','succeeded','failed','cancelled')",
      name: "marketplace_seller_payouts_status_check"
    add_check_constraint :marketplace_seller_payouts,
      "((status IN ('succeeded','failed','cancelled')) = (processed_at IS NOT NULL))",
      name: "marketplace_seller_payouts_processed_metadata_check"
    add_check_constraint :marketplace_seller_payouts,
      "((status = 'failed') = (failure_code IS NOT NULL))",
      name: "marketplace_seller_payouts_failure_metadata_check"

    add_foreign_key :marketplace_seller_payouts, :core_users,
                    column: :seller_user_id, on_delete: :restrict
    add_foreign_key :marketplace_seller_payouts, :marketplace_seller_payout_accounts,
                    column: :seller_payout_account_id, on_delete: :restrict
    add_foreign_key :marketplace_seller_ledger_entries, :marketplace_seller_payouts,
                    column: :seller_payout_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION marketplace_seller_payout_account_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            account_user_id uuid;
            account_provider text;
            account_status text;
          BEGIN
            SELECT user_id, provider, status
              INTO account_user_id, account_provider, account_status
            FROM marketplace_seller_payout_accounts
            WHERE id = NEW.seller_payout_account_id;

            IF account_user_id IS NULL OR account_user_id IS DISTINCT FROM NEW.seller_user_id OR
               account_provider IS DISTINCT FROM NEW.provider OR account_status IS DISTINCT FROM 'verified' THEN
              RAISE EXCEPTION 'marketplace_seller_payout_account_invalid' USING ERRCODE = '23514';
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_marketplace_seller_payout_account_integrity
            ON marketplace_seller_payouts;
          CREATE TRIGGER trg_marketplace_seller_payout_account_integrity
            BEFORE INSERT OR UPDATE ON marketplace_seller_payouts
            FOR EACH ROW EXECUTE FUNCTION marketplace_seller_payout_account_integrity();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_marketplace_seller_payout_account_integrity ON marketplace_seller_payouts;"
        execute "DROP FUNCTION IF EXISTS marketplace_seller_payout_account_integrity();"
      end
    end
  end
end
