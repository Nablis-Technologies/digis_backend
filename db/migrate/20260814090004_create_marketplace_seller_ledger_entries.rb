# frozen_string_literal: true

class CreateMarketplaceSellerLedgerEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_seller_ledger_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :seller_user_id, null: false
      t.uuid :event_id, null: false
      t.uuid :resale_sale_id
      # Foreign key is added after the payout table is created in the next migration.
      t.uuid :seller_payout_id
      t.uuid :reverses_entry_id
      t.string :type, null: false
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.timestamptz :available_at, null: false
      t.string :idempotency_key, null: false
      t.text :description
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :marketplace_seller_ledger_entries, :idempotency_key,
              unique: true,
              name: "idx_marketplace_seller_ledger_entries_on_idempotency_key"
    add_index :marketplace_seller_ledger_entries, %i[seller_user_id currency available_at],
              name: "idx_mkt_seller_ledger_seller_currency_avail"
    add_index :marketplace_seller_ledger_entries, %i[event_id type created_at],
              name: "idx_marketplace_seller_ledger_entries_on_event_type_created"
    add_index :marketplace_seller_ledger_entries, :resale_sale_id,
              name: "idx_marketplace_seller_ledger_entries_on_resale_sale"
    add_index :marketplace_seller_ledger_entries, :seller_payout_id,
              name: "idx_marketplace_seller_ledger_entries_on_seller_payout"

    add_check_constraint :marketplace_seller_ledger_entries,
      "type IN ('resale_proceeds','marketplace_fee','cancellation_reversal','chargeback','adjustment','payout')",
      name: "marketplace_seller_ledger_entries_type_check"
    add_check_constraint :marketplace_seller_ledger_entries,
      "amount_minor <> 0",
      name: "marketplace_seller_ledger_entries_nonzero_amount_check"
    add_check_constraint :marketplace_seller_ledger_entries,
      "((type = 'resale_proceeds' AND amount_minor > 0) OR " \
      "(type IN ('marketplace_fee','chargeback','payout') AND amount_minor < 0) OR " \
      "type IN ('cancellation_reversal','adjustment'))",
      name: "marketplace_seller_ledger_entries_sign_check"
    add_check_constraint :marketplace_seller_ledger_entries,
      "currency ~ '^[A-Z]{3}$'",
      name: "marketplace_seller_ledger_entries_currency_check"
    add_check_constraint :marketplace_seller_ledger_entries,
      "((type IN ('resale_proceeds','marketplace_fee','cancellation_reversal','chargeback') AND " \
      "resale_sale_id IS NOT NULL AND seller_payout_id IS NULL) OR " \
      "(type = 'payout' AND seller_payout_id IS NOT NULL AND resale_sale_id IS NULL) OR " \
      "(type = 'adjustment' AND resale_sale_id IS NULL AND seller_payout_id IS NULL))",
      name: "marketplace_seller_ledger_entries_reference_shape_check"

    add_foreign_key :marketplace_seller_ledger_entries, :core_users,
                    column: :seller_user_id, on_delete: :restrict
    add_foreign_key :marketplace_seller_ledger_entries, :events_events,
                    column: :event_id, on_delete: :restrict
    add_foreign_key :marketplace_seller_ledger_entries, :marketplace_resale_sales,
                    column: :resale_sale_id, on_delete: :restrict
    add_foreign_key :marketplace_seller_ledger_entries, :marketplace_seller_ledger_entries,
                    column: :reverses_entry_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION marketplace_seller_ledger_entry_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            sale_event_id uuid;
            sale_seller_id uuid;
            sale_currency text;
            payout_seller_id uuid;
            payout_currency text;
            original_amount bigint;
            original_currency text;
            original_seller_id uuid;
            original_event_id uuid;
          BEGIN
            IF NEW.resale_sale_id IS NOT NULL THEN
              SELECT event_id, seller_user_id, currency
                INTO sale_event_id, sale_seller_id, sale_currency
              FROM marketplace_resale_sales
              WHERE id = NEW.resale_sale_id;

              IF NEW.event_id IS DISTINCT FROM sale_event_id OR
                 NEW.seller_user_id IS DISTINCT FROM sale_seller_id OR
                 NEW.currency IS DISTINCT FROM sale_currency THEN
                RAISE EXCEPTION 'marketplace_seller_ledger_sale_scope' USING ERRCODE = '23514';
              END IF;
            END IF;

            IF NEW.seller_payout_id IS NOT NULL THEN
              SELECT seller_user_id, currency
                INTO payout_seller_id, payout_currency
              FROM marketplace_seller_payouts
              WHERE id = NEW.seller_payout_id;

              IF NEW.seller_user_id IS DISTINCT FROM payout_seller_id OR
                 NEW.currency IS DISTINCT FROM payout_currency THEN
                RAISE EXCEPTION 'marketplace_seller_ledger_payout_scope' USING ERRCODE = '23514';
              END IF;
            END IF;

            IF NEW.reverses_entry_id IS NOT NULL THEN
              SELECT amount_minor, currency, seller_user_id, event_id
                INTO original_amount, original_currency, original_seller_id, original_event_id
              FROM marketplace_seller_ledger_entries
              WHERE id = NEW.reverses_entry_id;

              IF original_amount IS NULL OR NEW.amount_minor IS DISTINCT FROM -original_amount OR
                 NEW.currency IS DISTINCT FROM original_currency OR
                 NEW.seller_user_id IS DISTINCT FROM original_seller_id OR
                 NEW.event_id IS DISTINCT FROM original_event_id THEN
                RAISE EXCEPTION 'marketplace_seller_ledger_reversal_scope' USING ERRCODE = '23514';
              END IF;
            END IF;

            RETURN NEW;
          END;
          $$;

          CREATE OR REPLACE FUNCTION marketplace_seller_ledger_entry_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            RAISE EXCEPTION 'marketplace_seller_ledger_entry_immutable' USING ERRCODE = '40001';
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_marketplace_seller_ledger_entry_integrity
            ON marketplace_seller_ledger_entries;
          CREATE TRIGGER trg_marketplace_seller_ledger_entry_integrity
            BEFORE INSERT ON marketplace_seller_ledger_entries
            FOR EACH ROW EXECUTE FUNCTION marketplace_seller_ledger_entry_integrity();

          DROP TRIGGER IF EXISTS trg_marketplace_seller_ledger_entry_immutable
            ON marketplace_seller_ledger_entries;
          CREATE TRIGGER trg_marketplace_seller_ledger_entry_immutable
            BEFORE UPDATE OR DELETE ON marketplace_seller_ledger_entries
            FOR EACH ROW EXECUTE FUNCTION marketplace_seller_ledger_entry_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_marketplace_seller_ledger_entry_immutable ON marketplace_seller_ledger_entries;"
        execute "DROP TRIGGER IF EXISTS trg_marketplace_seller_ledger_entry_integrity ON marketplace_seller_ledger_entries;"
        execute "DROP FUNCTION IF EXISTS marketplace_seller_ledger_entry_immutable();"
        execute "DROP FUNCTION IF EXISTS marketplace_seller_ledger_entry_integrity();"
      end
    end
  end
end
