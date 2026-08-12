# frozen_string_literal: true

class CreatePayments < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_payments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :order_id, null: false
      t.integer :attempt_number, null: false
      t.string :provider, null: false
      t.string :payment_method, null: false
      t.string :status, null: false, default: "created"
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.string :commercial_signature, limit: 64, null: false
      t.bigint :buyer_fee_minor, null: false, default: 0
      t.bigint :organizer_fee_minor, null: false, default: 0
      t.bigint :provider_fee_minor
      t.string :provider_fee_currency, limit: 3
      t.string :idempotency_key, null: false
      t.string :provider_reference
      t.string :failure_code
      t.string :raw_status
      t.integer :settlement_grace_minutes, null: false, default: 5
      t.timestamptz :settlement_grace_expires_at, null: false
      t.timestamptz :accepted_at
      t.timestamptz :superseded_at

      t.timestamps
    end

    add_index :orders_payments, %i[order_id attempt_number],
              unique: true,
              name: "idx_payments_on_order_and_attempt"
    add_index :orders_payments, %i[provider idempotency_key],
              unique: true,
              name: "idx_payments_on_provider_and_idempotency"
    add_index :orders_payments, %i[provider provider_reference],
              unique: true,
              where: "provider_reference IS NOT NULL",
              name: "idx_payments_on_provider_and_reference"
    add_index :orders_payments, :order_id,
              unique: true,
              where: "accepted_at IS NOT NULL",
              name: "idx_one_accepted_payment_per_order"
    add_index :orders_payments, :order_id,
              unique: true,
              where: "superseded_at IS NULL AND status IN ('created', 'processing')",
              name: "idx_one_current_payment_attempt"
    add_index :orders_payments, %i[status settlement_grace_expires_at],
              name: "idx_payments_on_status_and_grace_expiry"

    add_check_constraint :orders_payments,
      "attempt_number BETWEEN 1 AND 3",
      name: "orders_payments_attempt_number_check"
    add_check_constraint :orders_payments,
      "status IN ('created','processing','succeeded','failed','cancelled','unknown','timeout','reversed')",
      name: "orders_payments_status_check"
    add_check_constraint :orders_payments,
      "amount_minor > 0 AND buyer_fee_minor >= 0 AND organizer_fee_minor >= 0 AND " \
      "(provider_fee_minor IS NULL OR provider_fee_minor >= 0)",
      name: "orders_payments_amounts_check"
    add_check_constraint :orders_payments,
      "currency ~ '^[A-Z]{3}$' AND " \
      "(provider_fee_currency IS NULL OR provider_fee_currency ~ '^[A-Z]{3}$')",
      name: "orders_payments_currency_check"
    add_check_constraint :orders_payments,
      "commercial_signature ~ '^[0-9a-f]{64}$'",
      name: "orders_payments_commercial_signature_check"
    add_check_constraint :orders_payments,
      "settlement_grace_minutes BETWEEN 3 AND 15",
      name: "orders_payments_grace_minutes_check"
    add_check_constraint :orders_payments,
      "(provider_fee_minor IS NULL) = (provider_fee_currency IS NULL) AND " \
      "(provider_fee_minor IS NULL OR provider_fee_currency = currency)",
      name: "orders_payments_provider_fee_pair_check"
    add_check_constraint :orders_payments,
      "accepted_at IS NULL OR status = 'succeeded'",
      name: "orders_payments_accepted_state_check"
    add_foreign_key :orders_payments, :orders_orders,
                    column: :order_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION orders_payment_snapshot_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            expected_amount bigint;
            expected_currency text;
          BEGIN
            SELECT total_minor, charge_currency
              INTO expected_amount, expected_currency
            FROM orders_orders
            WHERE id = NEW.order_id;

            IF NOT FOUND OR NEW.amount_minor IS DISTINCT FROM expected_amount OR
               NEW.currency IS DISTINCT FROM expected_currency THEN
              RAISE EXCEPTION 'orders_payment_order_amount_currency_mismatch'
                USING ERRCODE = '23514';
            END IF;

            IF EXISTS (
              SELECT 1
              FROM orders_payments
              WHERE order_id = NEW.order_id
                AND id IS DISTINCT FROM NEW.id
                AND commercial_signature IS DISTINCT FROM NEW.commercial_signature
            ) THEN
              RAISE EXCEPTION 'orders_payment_commercial_signature_mismatch'
                USING ERRCODE = '23514';
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_orders_payment_snapshot_integrity
            ON orders_payments;
          CREATE TRIGGER trg_orders_payment_snapshot_integrity
            BEFORE INSERT OR UPDATE ON orders_payments
            FOR EACH ROW EXECUTE FUNCTION orders_payment_snapshot_integrity();
        SQL
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS trg_orders_payment_snapshot_integrity
            ON orders_payments;
          DROP FUNCTION IF EXISTS orders_payment_snapshot_integrity();
        SQL
      end
    end
  end
end
