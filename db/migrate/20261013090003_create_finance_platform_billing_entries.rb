# frozen_string_literal: true

class CreateFinancePlatformBillingEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :finance_platform_billing_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :billing_purchase_id, null: false
      t.uuid :payment_id, null: false
      t.uuid :refund_id
      t.string :type, null: false
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.string :idempotency_key, limit: 64, null: false

      t.timestamps
    end

    add_index :finance_platform_billing_entries, :idempotency_key, unique: true
    add_index :finance_platform_billing_entries, %i[payment_id type], unique: true,
      where: "type IN ('featured_placement_charge','provider_fee')",
      name: "idx_platform_billing_entries_payment_type"
    add_index :finance_platform_billing_entries, :refund_id, unique: true,
      where: "refund_id IS NOT NULL"

    add_check_constraint :finance_platform_billing_entries,
      "type IN ('featured_placement_charge','provider_fee','featured_placement_refund')",
      name: "finance_platform_billing_entries_type_check"
    add_check_constraint :finance_platform_billing_entries,
      "amount_minor <> 0 AND currency = 'ETB' AND idempotency_key ~ '^[0-9a-f]{64}$'",
      name: "finance_platform_billing_entries_snapshot_check"
    add_check_constraint :finance_platform_billing_entries,
      "(type = 'featured_placement_charge' AND amount_minor > 0 AND refund_id IS NULL) OR " \
      "(type = 'provider_fee' AND amount_minor < 0 AND refund_id IS NULL) OR " \
      "(type = 'featured_placement_refund' AND amount_minor < 0 AND refund_id IS NOT NULL)",
      name: "finance_platform_billing_entries_shape_check"

    add_foreign_key :finance_platform_billing_entries, :orders_billing_purchases,
      column: :billing_purchase_id, on_delete: :restrict
    add_foreign_key :finance_platform_billing_entries, :orders_payments,
      column: :payment_id, on_delete: :restrict
    add_foreign_key :finance_platform_billing_entries, :orders_refunds,
      column: :refund_id, on_delete: :restrict

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION finance_platform_billing_entries_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            RAISE EXCEPTION 'finance_platform_billing_entries_are_immutable' USING ERRCODE = '23514';
          END;
          $$;

          CREATE TRIGGER trg_finance_platform_billing_entries_immutable
            BEFORE UPDATE OR DELETE ON finance_platform_billing_entries
            FOR EACH ROW EXECUTE FUNCTION finance_platform_billing_entries_immutable();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS trg_finance_platform_billing_entries_immutable ON finance_platform_billing_entries"
        execute "DROP FUNCTION IF EXISTS finance_platform_billing_entries_immutable()"
      end
    end
  end
end
