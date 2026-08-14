# frozen_string_literal: true

# The organizer ledger is deliberately a fact table: historical financial rows
# are inserted once and corrected with linked opposite rows rather than edits.
class CreateFinanceLedgerEntries < ActiveRecord::Migration[8.1]
  def up
    create_table :finance_ledger_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :event_id
      t.uuid :order_id
      t.uuid :payment_id
      t.uuid :refund_id
      t.uuid :reverses_entry_id
      t.string :type, null: false
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.timestamptz :available_at, null: false
      t.string :idempotency_key, null: false
      t.string :description
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :finance_ledger_entries, :idempotency_key, unique: true,
              name: "idx_finance_ledger_entries_on_idempotency_key"
    add_index :finance_ledger_entries, %i[organization_id currency available_at created_at],
              name: "idx_finance_ledger_entries_on_org_currency_availability"
    add_index :finance_ledger_entries, %i[event_id created_at],
              name: "idx_finance_ledger_entries_on_event_created_at"
    add_index :finance_ledger_entries, :order_id
    add_index :finance_ledger_entries, :payment_id
    add_index :finance_ledger_entries, :refund_id
    add_index :finance_ledger_entries, :reverses_entry_id

    add_check_constraint :finance_ledger_entries,
      "type IN ('sale','platform_fee','processing_fee','refund','chargeback','adjustment','payout')",
      name: "finance_ledger_entries_type_check"
    add_check_constraint :finance_ledger_entries,
      "amount_minor <> 0",
      name: "finance_ledger_entries_nonzero_amount"
    add_check_constraint :finance_ledger_entries,
      "currency ~ '^[A-Z]{3}$'",
      name: "finance_ledger_entries_currency_check"
    add_check_constraint :finance_ledger_entries,
      "((type = 'sale' AND amount_minor > 0) OR " \
      "(type IN ('platform_fee','processing_fee','refund','chargeback','payout') AND amount_minor < 0) OR " \
      "type = 'adjustment')",
      name: "finance_ledger_entries_sign_check"

    add_foreign_key :finance_ledger_entries, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :finance_ledger_entries, :events_events,
                    column: :event_id, on_delete: :restrict
    add_foreign_key :finance_ledger_entries, :orders_orders,
                    column: :order_id, on_delete: :restrict
    add_foreign_key :finance_ledger_entries, :orders_payments,
                    column: :payment_id, on_delete: :restrict
    add_foreign_key :finance_ledger_entries, :orders_refunds,
                    column: :refund_id, on_delete: :restrict
    add_foreign_key :finance_ledger_entries, :finance_ledger_entries,
                    column: :reverses_entry_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION finance_ledger_entry_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        event_organization_id uuid;
        order_event_id uuid;
        order_currency text;
        payment_order_id uuid;
        refund_payment_id uuid;
        original_amount bigint;
        original_currency text;
        original_organization_id uuid;
        original_event_id uuid;
        original_type text;
      BEGIN
        IF NEW.event_id IS NULL AND NEW.type <> 'payout' THEN
          IF NEW.type <> 'adjustment' OR NEW.reverses_entry_id IS NULL THEN
            RAISE EXCEPTION 'finance_ledger_event_required' USING ERRCODE = '23514';
          END IF;

          SELECT type, event_id
            INTO original_type, original_event_id
          FROM finance_ledger_entries
          WHERE id = NEW.reverses_entry_id;

          IF original_type IS DISTINCT FROM 'payout' OR original_event_id IS NOT NULL THEN
            RAISE EXCEPTION 'finance_ledger_event_required' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.event_id IS NOT NULL THEN
          SELECT organization_id
            INTO event_organization_id
          FROM events_events
          WHERE id = NEW.event_id;

          IF event_organization_id IS NULL OR NEW.organization_id IS DISTINCT FROM event_organization_id THEN
            RAISE EXCEPTION 'finance_ledger_event_organization_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.order_id IS NOT NULL THEN
          SELECT event_id, settlement_currency
            INTO order_event_id, order_currency
          FROM orders_orders
          WHERE id = NEW.order_id;

          IF NEW.event_id IS DISTINCT FROM order_event_id OR NEW.currency IS DISTINCT FROM order_currency THEN
            RAISE EXCEPTION 'finance_ledger_order_event_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.payment_id IS NOT NULL THEN
          SELECT order_id
            INTO payment_order_id
          FROM orders_payments
          WHERE id = NEW.payment_id;

          IF NEW.order_id IS DISTINCT FROM payment_order_id THEN
            RAISE EXCEPTION 'finance_ledger_payment_order_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.refund_id IS NOT NULL THEN
          SELECT payment_id
            INTO refund_payment_id
          FROM orders_refunds
          WHERE id = NEW.refund_id;

          IF NEW.payment_id IS DISTINCT FROM refund_payment_id THEN
            RAISE EXCEPTION 'finance_ledger_refund_payment_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.reverses_entry_id IS NOT NULL THEN
          SELECT amount_minor, currency, organization_id, event_id
            INTO original_amount, original_currency, original_organization_id, original_event_id
          FROM finance_ledger_entries
          WHERE id = NEW.reverses_entry_id;

          IF original_amount IS NULL OR NEW.amount_minor IS DISTINCT FROM -original_amount OR
             NEW.currency IS DISTINCT FROM original_currency OR
             NEW.organization_id IS DISTINCT FROM original_organization_id OR
             NEW.event_id IS DISTINCT FROM original_event_id THEN
            RAISE EXCEPTION 'finance_ledger_reversal_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION finance_ledger_entry_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'finance_ledger_entry_immutable' USING ERRCODE = '40001';
      END;
      $$;

      CREATE TRIGGER trg_finance_ledger_entry_integrity
        BEFORE INSERT OR UPDATE ON finance_ledger_entries
        FOR EACH ROW EXECUTE FUNCTION finance_ledger_entry_integrity();
      CREATE TRIGGER trg_finance_ledger_entry_immutable
        BEFORE UPDATE OR DELETE ON finance_ledger_entries
        FOR EACH ROW EXECUTE FUNCTION finance_ledger_entry_immutable();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_finance_ledger_entry_immutable ON finance_ledger_entries;"
    execute "DROP TRIGGER IF EXISTS trg_finance_ledger_entry_integrity ON finance_ledger_entries;"
    execute "DROP FUNCTION IF EXISTS finance_ledger_entry_immutable();"
    execute "DROP FUNCTION IF EXISTS finance_ledger_entry_integrity();"
    drop_table :finance_ledger_entries
  end
end
