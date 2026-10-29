# frozen_string_literal: true

class CreateRefunds < ActiveRecord::Migration[8.1]
  def up
    create_table :orders_refunds, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :payment_id, null: false
      t.uuid :billing_purchase_id
      t.uuid :event_cancellation_id
      t.string :type, null: false
      t.string :idempotency_key, null: false
      t.string :provider_reference
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.string :status, null: false, default: "created"
      t.bigint :provider_fee_minor
      t.string :provider_fee_currency, limit: 3
      t.timestamptz :provider_fee_recorded_at
      t.string :pending_reason
      t.timestamptz :next_retry_at
      t.string :reason_code, null: false
      t.text :reason
      t.uuid :manual_resolved_by_id
      t.string :manual_resolution_reason
      t.string :manual_evidence_reference
      t.timestamptz :manual_resolved_at

      t.timestamps
    end

    add_index :orders_refunds, :payment_id
    add_index :orders_refunds, :billing_purchase_id
    add_index :orders_refunds, :event_cancellation_id
    add_index :orders_refunds, %i[event_cancellation_id status],
              where: "event_cancellation_id IS NOT NULL",
              name: "idx_refunds_on_cancellation_and_status"
    add_index :orders_refunds, :idempotency_key, unique: true
    add_index :orders_refunds, %i[status next_retry_at]
    add_index :orders_refunds, :payment_id,
              unique: true,
              where: "type = 'payment_reversal'",
              name: "idx_one_payment_reversal_per_payment"

    add_check_constraint :orders_refunds,
      "type IN ('item_refund','payment_reversal','billing_purchase_refund')",
      name: "orders_refunds_type_check"
    add_check_constraint :orders_refunds,
      "status IN ('created','pending_funds','processing','manual_review','succeeded','failed')",
      name: "orders_refunds_status_check"
    add_check_constraint :orders_refunds,
      "(type = 'billing_purchase_refund' AND billing_purchase_id IS NOT NULL AND event_cancellation_id IS NULL) OR " \
      "(type <> 'billing_purchase_refund' AND billing_purchase_id IS NULL)",
      name: "orders_refunds_billing_purchase_shape_check"
    add_check_constraint :orders_refunds,
      "type <> 'billing_purchase_refund' OR reason_code IN ('featured_placement_cancelled','event_cancelled')",
      name: "orders_refunds_billing_purchase_reason_check"
    add_check_constraint :orders_refunds,
      "amount_minor > 0",
      name: "refund_amount_positive"
    add_check_constraint :orders_refunds,
      "currency ~ '^[A-Z]{3}$'",
      name: "refund_currency_iso"
    add_check_constraint :orders_refunds,
      "(provider_fee_minor IS NULL AND provider_fee_currency IS NULL AND provider_fee_recorded_at IS NULL) OR " \
      "(provider_fee_minor IS NOT NULL AND provider_fee_minor >= 0 AND provider_fee_currency IS NOT NULL AND " \
      "provider_fee_currency ~ '^[A-Z]{3}$' AND provider_fee_recorded_at IS NOT NULL)",
      name: "orders_refunds_provider_fee_pair_check"
    add_check_constraint :orders_refunds,
      "status <> 'pending_funds' OR pending_reason IS NOT NULL",
      name: "pending_funds_has_reason"
    add_check_constraint :orders_refunds,
      "manual_resolved_at IS NULL OR (manual_resolved_by_id IS NOT NULL AND " \
      "btrim(manual_resolution_reason) <> '' AND btrim(manual_evidence_reference) <> '')",
      name: "orders_refunds_manual_resolution_check"

    add_foreign_key :orders_refunds, :orders_payments,
                    column: :payment_id, on_delete: :restrict
    add_foreign_key :orders_refunds, :orders_billing_purchases,
                    column: :billing_purchase_id, on_delete: :restrict
    add_foreign_key :orders_refunds, :events_event_cancellations,
                    column: :event_cancellation_id, on_delete: :restrict
    add_foreign_key :orders_refunds, :core_users,
                    column: :manual_resolved_by_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION orders_refund_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        payment_status text;
        accepted_at timestamptz;
        payment_billing_purchase_id uuid;
        payment_amount bigint;
        payment_currency text;
      BEGIN
        SELECT payments.status, payments.accepted_at, payments.billing_purchase_id,
               payments.amount_minor, payments.currency
          INTO payment_status, accepted_at, payment_billing_purchase_id, payment_amount, payment_currency
        FROM orders_payments AS payments
        WHERE payments.id = NEW.payment_id;

        IF NEW.currency IS DISTINCT FROM payment_currency THEN
          RAISE EXCEPTION 'orders_refund_payment_currency_scope' USING ERRCODE = '23514';
        END IF;

        IF NEW.type = 'payment_reversal' AND
           (payment_status IS DISTINCT FROM 'succeeded' OR
            (accepted_at IS NOT NULL AND payment_billing_purchase_id IS NULL) OR
            NEW.amount_minor IS DISTINCT FROM payment_amount OR
            NEW.currency IS DISTINCT FROM payment_currency) THEN
          RAISE EXCEPTION 'orders_payment_reversal_integrity' USING ERRCODE = '23514';
        END IF;

        IF NEW.type = 'billing_purchase_refund' AND
           (payment_status IS DISTINCT FROM 'succeeded' OR accepted_at IS NULL OR
            payment_billing_purchase_id IS DISTINCT FROM NEW.billing_purchase_id OR
            NEW.amount_minor > payment_amount) THEN
          RAISE EXCEPTION 'orders_billing_purchase_refund_integrity' USING ERRCODE = '23514';
        END IF;

        IF NEW.event_cancellation_id IS NOT NULL AND EXISTS (
          SELECT 1
          FROM events_event_cancellations AS cancellations
          JOIN orders_payments AS cancellation_payments
            ON cancellation_payments.id = NEW.payment_id
          JOIN orders_orders AS cancellation_orders
            ON cancellation_orders.id = cancellation_payments.order_id
          WHERE cancellations.id = NEW.event_cancellation_id
            AND cancellations.event_id IS DISTINCT FROM cancellation_orders.event_id
        ) THEN
          RAISE EXCEPTION 'orders_refund_cancellation_event_scope' USING ERRCODE = '23514';
        END IF;

        IF NEW.status IN ('created', 'pending_funds', 'processing', 'manual_review', 'succeeded') AND
           (SELECT COALESCE(SUM(amount_minor), 0)
            FROM orders_refunds
            WHERE payment_id = NEW.payment_id
              AND status IN ('created', 'pending_funds', 'processing', 'manual_review', 'succeeded')
              AND id IS DISTINCT FROM NEW.id) + NEW.amount_minor > payment_amount THEN
          RAISE EXCEPTION 'orders_refunds_payment_amount_exceeded' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_orders_refund_integrity
        BEFORE INSERT OR UPDATE ON orders_refunds
        FOR EACH ROW EXECUTE FUNCTION orders_refund_integrity();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_orders_refund_integrity ON orders_refunds;"
    drop_table :orders_refunds
    execute "DROP FUNCTION IF EXISTS orders_refund_integrity();"
  end
end
