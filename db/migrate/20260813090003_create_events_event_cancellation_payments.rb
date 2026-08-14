# frozen_string_literal: true

class CreateEventsEventCancellationPayments < ActiveRecord::Migration[8.1]
  def change
    # This table is orchestration evidence, not a second financial source of
    # truth. One row per accepted payment makes retries and no-refund outcomes
    # explicit without creating artificial zero-value refund obligations.
    create_table :events_event_cancellation_payments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_cancellation_id, null: false
      t.uuid :payment_id, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.timestamptz :next_retry_at
      t.timestamptz :resolved_at
      t.text :last_error
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :events_event_cancellation_payments,
      %i[event_cancellation_id payment_id], unique: true,
      name: "idx_event_cancellation_payments_unique"
    add_index :events_event_cancellation_payments,
      %i[event_cancellation_id status next_retry_at],
      name: "idx_event_cancellation_payments_work"
    add_index :events_event_cancellation_payments, :payment_id

    add_foreign_key :events_event_cancellation_payments, :events_event_cancellations,
                    column: :event_cancellation_id, on_delete: :cascade
    add_foreign_key :events_event_cancellation_payments, :orders_payments,
                    column: :payment_id, on_delete: :restrict

    add_check_constraint :events_event_cancellation_payments,
      "status IN ('pending','processing','resolved','failed')",
      name: "event_cancellation_payments_status_check"
    add_check_constraint :events_event_cancellation_payments,
      "attempts >= 0 AND lock_version >= 0",
      name: "event_cancellation_payments_counters_check"
    add_check_constraint :events_event_cancellation_payments,
      "(status = 'resolved' AND resolved_at IS NOT NULL) OR " \
      "(status <> 'resolved' AND resolved_at IS NULL)",
      name: "event_cancellation_payments_resolved_shape_check"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION event_cancellation_payment_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        cancellation_event_id uuid;
        payment_event_id uuid;
        payment_status text;
        accepted_at timestamptz;
      BEGIN
        SELECT event_id INTO cancellation_event_id
        FROM events_event_cancellations
        WHERE id = NEW.event_cancellation_id;

        SELECT orders.event_id, payments.status, payments.accepted_at
          INTO payment_event_id, payment_status, accepted_at
        FROM orders_payments AS payments
        JOIN orders_orders AS orders ON orders.id = payments.order_id
        WHERE payments.id = NEW.payment_id;

        IF cancellation_event_id IS DISTINCT FROM payment_event_id THEN
          RAISE EXCEPTION 'event_cancellation_payment_event_scope' USING ERRCODE = '23514';
        END IF;

        IF payment_status IS DISTINCT FROM 'succeeded' OR accepted_at IS NULL THEN
          RAISE EXCEPTION 'event_cancellation_payment_not_accepted' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_event_cancellation_payment_integrity
        BEFORE INSERT OR UPDATE ON events_event_cancellation_payments
        FOR EACH ROW EXECUTE FUNCTION event_cancellation_payment_integrity();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_event_cancellation_payment_integrity ON events_event_cancellation_payments;"
    execute "DROP FUNCTION IF EXISTS event_cancellation_payment_integrity();"
    drop_table :events_event_cancellation_payments
  end
end
