# frozen_string_literal: true

class CreateMarketplaceSellerPayoutAllocations < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_seller_payout_allocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :payout_id, null: false
      t.uuid :seller_ledger_entry_id, null: false
      t.bigint :amount_minor, null: false
      t.string :status, null: false, default: "reserved"
      t.timestamptz :consumed_at
      t.timestamptz :released_at

      t.timestamps
    end

    add_index :marketplace_seller_payout_allocations, %i[payout_id seller_ledger_entry_id],
              unique: true,
              name: "idx_marketplace_payout_allocations_on_payout_and_ledger"
    add_index :marketplace_seller_payout_allocations, %i[seller_ledger_entry_id status],
              name: "idx_marketplace_payout_allocations_on_ledger_and_status"

    add_check_constraint :marketplace_seller_payout_allocations,
      "amount_minor > 0",
      name: "marketplace_seller_payout_allocations_positive_amount_check"
    add_check_constraint :marketplace_seller_payout_allocations,
      "status IN ('reserved','consumed','released')",
      name: "marketplace_seller_payout_allocations_status_check"
    add_check_constraint :marketplace_seller_payout_allocations,
      "(status = 'consumed') = (consumed_at IS NOT NULL)",
      name: "marketplace_seller_payout_allocations_consumed_metadata_check"
    add_check_constraint :marketplace_seller_payout_allocations,
      "(status = 'released') = (released_at IS NOT NULL)",
      name: "marketplace_seller_payout_allocations_released_metadata_check"

    add_foreign_key :marketplace_seller_payout_allocations, :marketplace_seller_payouts,
                    column: :payout_id, on_delete: :restrict
    add_foreign_key :marketplace_seller_payout_allocations, :marketplace_seller_ledger_entries,
                    column: :seller_ledger_entry_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION marketplace_seller_payout_allocation_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            payout_seller_id uuid;
            payout_currency text;
            ledger_seller_id uuid;
            ledger_currency text;
            ledger_type text;
            ledger_amount bigint;
            allocated_amount bigint;
          BEGIN
            SELECT seller_user_id, currency
              INTO payout_seller_id, payout_currency
            FROM marketplace_seller_payouts
            WHERE id = NEW.payout_id;

            SELECT seller_user_id, currency, type, amount_minor
              INTO ledger_seller_id, ledger_currency, ledger_type, ledger_amount
            FROM marketplace_seller_ledger_entries
            WHERE id = NEW.seller_ledger_entry_id
            FOR UPDATE;

            IF payout_seller_id IS NULL OR ledger_seller_id IS NULL OR
               payout_seller_id IS DISTINCT FROM ledger_seller_id OR
               payout_currency IS DISTINCT FROM ledger_currency OR
               ledger_type = 'payout' OR ledger_amount <= 0 OR NEW.amount_minor <= 0 THEN
              RAISE EXCEPTION 'marketplace_seller_payout_allocation_scope_invalid' USING ERRCODE = '23514';
            END IF;

            SELECT COALESCE(sum(amount_minor), 0)
              INTO allocated_amount
            FROM marketplace_seller_payout_allocations
            WHERE seller_ledger_entry_id = NEW.seller_ledger_entry_id
              AND status IN ('reserved','consumed')
              AND id IS DISTINCT FROM NEW.id;

            IF allocated_amount + NEW.amount_minor > ledger_amount THEN
              RAISE EXCEPTION 'marketplace_seller_payout_allocation_exceeds_ledger'
                USING ERRCODE = '23514';
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_marketplace_seller_payout_allocation_integrity
            ON marketplace_seller_payout_allocations;
          CREATE TRIGGER trg_marketplace_seller_payout_allocation_integrity
            BEFORE INSERT OR UPDATE ON marketplace_seller_payout_allocations
            FOR EACH ROW EXECUTE FUNCTION marketplace_seller_payout_allocation_integrity();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_marketplace_seller_payout_allocation_integrity ON marketplace_seller_payout_allocations;"
        execute "DROP FUNCTION IF EXISTS marketplace_seller_payout_allocation_integrity();"
      end
    end
  end
end
