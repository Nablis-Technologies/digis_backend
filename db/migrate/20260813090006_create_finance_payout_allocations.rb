# frozen_string_literal: true

class CreateFinancePayoutAllocations < ActiveRecord::Migration[8.1]
  def up
    create_table :finance_payout_allocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :payout_id, null: false
      t.uuid :ledger_entry_id, null: false
      t.bigint :amount_minor, null: false
      t.string :status, null: false, default: "reserved"
      t.timestamptz :consumed_at
      t.timestamptz :released_at
      t.timestamps
    end

    add_index :finance_payout_allocations, %i[payout_id ledger_entry_id], unique: true,
              name: "idx_finance_payout_allocations_on_payout_and_ledger"
    add_index :finance_payout_allocations, %i[ledger_entry_id status],
              name: "idx_finance_payout_allocations_on_ledger_and_status"

    add_check_constraint :finance_payout_allocations,
      "amount_minor <> 0",
      name: "finance_payout_allocations_nonzero_amount_check"
    add_check_constraint :finance_payout_allocations,
      "status IN ('reserved','consumed','released')",
      name: "finance_payout_allocations_status_check"
    add_check_constraint :finance_payout_allocations,
      "(status = 'consumed') = (consumed_at IS NOT NULL)",
      name: "finance_payout_allocations_consumed_at_check"
    add_check_constraint :finance_payout_allocations,
      "(status = 'released') = (released_at IS NOT NULL)",
      name: "finance_payout_allocations_released_at_check"

    add_foreign_key :finance_payout_allocations, :finance_payouts,
                    column: :payout_id, on_delete: :restrict
    add_foreign_key :finance_payout_allocations, :finance_ledger_entries,
                    column: :ledger_entry_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION finance_payout_allocation_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        payout_organization_id uuid;
        payout_currency text;
        ledger_organization_id uuid;
        ledger_currency text;
        ledger_type text;
        ledger_amount bigint;
        allocated_amount bigint;
      BEGIN
        SELECT organization_id, currency
          INTO payout_organization_id, payout_currency
        FROM finance_payouts
        WHERE id = NEW.payout_id;

        SELECT organization_id, currency, type, amount_minor
          INTO ledger_organization_id, ledger_currency, ledger_type, ledger_amount
        FROM finance_ledger_entries
        WHERE id = NEW.ledger_entry_id;

        IF payout_organization_id IS NULL OR ledger_organization_id IS NULL OR
           payout_organization_id IS DISTINCT FROM ledger_organization_id OR
           payout_currency IS DISTINCT FROM ledger_currency THEN
          RAISE EXCEPTION 'finance_payout_scope_mismatch' USING ERRCODE = '23514';
        END IF;

        IF ledger_type = 'payout' THEN
          RAISE EXCEPTION 'finance_payout_cannot_allocate_payout' USING ERRCODE = '23514';
        END IF;

        IF (ledger_amount > 0 AND NEW.amount_minor <= 0) OR
           (ledger_amount < 0 AND NEW.amount_minor >= 0) OR
           abs(NEW.amount_minor) > abs(ledger_amount) THEN
          RAISE EXCEPTION 'finance_payout_allocation_sign_or_amount_invalid' USING ERRCODE = '23514';
        END IF;

        SELECT COALESCE(sum(abs(amount_minor)), 0)
          INTO allocated_amount
        FROM finance_payout_allocations
        WHERE ledger_entry_id = NEW.ledger_entry_id
          AND status IN ('reserved', 'consumed')
          AND id IS DISTINCT FROM NEW.id;

        IF allocated_amount + abs(NEW.amount_minor) > abs(ledger_amount) THEN
          RAISE EXCEPTION 'finance_payout_allocation_exceeds_ledger' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION finance_payout_allocation_totals()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        payout_status text;
        payout_amount bigint;
        allocated_amount bigint;
      BEGIN
        SELECT status, amount_minor
          INTO payout_status, payout_amount
        FROM finance_payouts
        WHERE id = COALESCE(NEW.payout_id, OLD.payout_id);

        IF payout_status IN ('pending', 'processing', 'paid') THEN
          SELECT COALESCE(sum(amount_minor), 0)
            INTO allocated_amount
          FROM finance_payout_allocations
          WHERE payout_id = COALESCE(NEW.payout_id, OLD.payout_id)
            AND status IN ('reserved', 'consumed');

          IF allocated_amount IS DISTINCT FROM payout_amount THEN
            RAISE EXCEPTION 'finance_payout_net_total_mismatch' USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN COALESCE(NEW, OLD);
      END;
      $$;

      CREATE CONSTRAINT TRIGGER trg_finance_payout_allocation_integrity
        AFTER INSERT OR UPDATE OR DELETE ON finance_payout_allocations
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION finance_payout_allocation_totals();
      CREATE TRIGGER trg_finance_payout_allocation_scope
        BEFORE INSERT OR UPDATE ON finance_payout_allocations
        FOR EACH ROW EXECUTE FUNCTION finance_payout_allocation_integrity();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_finance_payout_allocation_scope ON finance_payout_allocations;"
    execute "DROP TRIGGER IF EXISTS trg_finance_payout_allocation_integrity ON finance_payout_allocations;"
    execute "DROP FUNCTION IF EXISTS finance_payout_allocation_totals();"
    execute "DROP FUNCTION IF EXISTS finance_payout_allocation_integrity();"
    drop_table :finance_payout_allocations
  end
end
