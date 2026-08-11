# frozen_string_literal: true

class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_orders, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :buyer_user_id, null: false
      t.string :sales_channel, null: false, default: "online"
      t.uuid :initiated_by_id
      t.uuid :replaces_order_id
      t.string :status, null: false, default: "draft"
      t.string :closed_reason
      t.string :charge_currency, limit: 3, null: false
      t.bigint :subtotal_minor, null: false
      t.bigint :discount_minor, null: false, default: 0
      t.bigint :subsidy_minor, null: false, default: 0
      t.bigint :fee_minor, null: false, default: 0
      t.bigint :tax_minor, null: false, default: 0
      t.bigint :adjustment_minor, null: false, default: 0
      t.bigint :total_minor, null: false
      t.string :settlement_currency, limit: 3, null: false
      t.bigint :settlement_total_minor, null: false
      t.decimal :exchange_rate, precision: 24, scale: 12, null: false, default: 1
      t.string :exchange_rate_source, null: false
      t.timestamptz :exchange_rate_quoted_at
      t.timestamptz :exchange_rate_expires_at
      t.timestamptz :expires_at, null: false
      t.timestamptz :paid_at
      t.integer :lock_version, null: false, default: 0
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :creation_request_digest, limit: 64, null: false

      t.timestamps
    end

    add_check_constraint :orders_orders,
      "status IN ('draft','pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded')",
      name: "orders_orders_status_check"
    add_check_constraint :orders_orders,
      "sales_channel IN ('online','walk_up','resale')",
      name: "orders_orders_sales_channel_check"
    add_check_constraint :orders_orders,
      "charge_currency ~ '^[A-Z]{3}$' AND settlement_currency ~ '^[A-Z]{3}$'",
      name: "orders_orders_currency_check"
    add_check_constraint :orders_orders,
      "subtotal_minor >= 0 AND discount_minor >= 0 AND subsidy_minor >= 0 AND " \
      "fee_minor >= 0 AND tax_minor >= 0 AND settlement_total_minor >= 0",
      name: "orders_orders_amounts_check"
    add_check_constraint :orders_orders,
      "total_minor = subtotal_minor - discount_minor - subsidy_minor + fee_minor + tax_minor + adjustment_minor",
      name: "orders_orders_total_reconciles"
    add_check_constraint :orders_orders,
      "exchange_rate > 0",
      name: "orders_orders_exchange_rate_check"
    add_check_constraint :orders_orders,
      "((charge_currency = settlement_currency AND exchange_rate = 1) OR " \
      "(charge_currency <> settlement_currency AND exchange_rate_quoted_at IS NOT NULL AND " \
      "exchange_rate_expires_at IS NOT NULL AND exchange_rate_expires_at > exchange_rate_quoted_at))",
      name: "orders_orders_exchange_metadata_check"
    add_check_constraint :orders_orders,
      "lock_version >= 0",
      name: "orders_orders_lock_version_check"
    add_check_constraint :orders_orders,
      "((status IN ('expired','cancelled') AND closed_reason IS NOT NULL) OR " \
      "(status NOT IN ('expired','cancelled') AND closed_reason IS NULL))",
      name: "orders_orders_closed_reason_check"
    add_check_constraint :orders_orders,
      "((status IN ('paid','fulfilled','partially_refunded','refunded') AND paid_at IS NOT NULL) OR " \
      "(status NOT IN ('paid','fulfilled','partially_refunded','refunded') AND paid_at IS NULL))",
      name: "orders_orders_paid_at_check"
    add_check_constraint :orders_orders,
      "replaces_order_id IS NULL OR replaces_order_id <> id",
      name: "orders_orders_replacement_self_check"
    add_check_constraint :orders_orders,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND creation_request_digest ~ '^[0-9a-f]{64}$'",
      name: "orders_orders_creation_digests_check"

    add_index :orders_orders, %i[event_id status expires_at],
              name: "idx_orders_on_event_status_expiry"
    add_index :orders_orders, %i[buyer_user_id event_id],
              unique: true,
              where: "status IN ('draft','pending_payment')",
              name: "idx_one_active_checkout_per_buyer_event"
    add_index :orders_orders, :replaces_order_id,
              unique: true,
              where: "replaces_order_id IS NOT NULL",
              name: "idx_orders_on_replacement"
    add_index :orders_orders, :idempotency_key_digest,
              unique: true,
              name: "idx_orders_on_idempotency_digest"
    add_index :orders_orders, :creation_request_digest,
              name: "idx_orders_on_creation_request_digest"

    add_foreign_key :orders_orders, :events_events, column: :event_id, on_delete: :restrict
    add_foreign_key :orders_orders, :core_users, column: :buyer_user_id, on_delete: :restrict
    add_foreign_key :orders_orders, :core_users, column: :initiated_by_id, on_delete: :restrict
    add_foreign_key :orders_orders, :orders_orders,
                    column: :replaces_order_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION orders_order_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            IF OLD.status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') OR
               (TG_OP <> 'DELETE' AND NEW.status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded')) THEN
              IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'orders_order_snapshot_immutable' USING ERRCODE = '40001';
              END IF;

              IF (OLD.event_id, OLD.buyer_user_id, OLD.sales_channel, OLD.initiated_by_id,
                  OLD.replaces_order_id, OLD.charge_currency, OLD.subtotal_minor,
                  OLD.discount_minor, OLD.subsidy_minor, OLD.fee_minor, OLD.tax_minor,
                  OLD.adjustment_minor, OLD.total_minor, OLD.settlement_currency,
                  OLD.settlement_total_minor, OLD.exchange_rate, OLD.exchange_rate_source,
                  OLD.exchange_rate_quoted_at, OLD.exchange_rate_expires_at, OLD.expires_at,
                  OLD.idempotency_key_digest, OLD.creation_request_digest)
                 IS DISTINCT FROM
                 (NEW.event_id, NEW.buyer_user_id, NEW.sales_channel, NEW.initiated_by_id,
                  NEW.replaces_order_id, NEW.charge_currency, NEW.subtotal_minor,
                  NEW.discount_minor, NEW.subsidy_minor, NEW.fee_minor, NEW.tax_minor,
                  NEW.adjustment_minor, NEW.total_minor, NEW.settlement_currency,
                  NEW.settlement_total_minor, NEW.exchange_rate, NEW.exchange_rate_source,
                  NEW.exchange_rate_quoted_at, NEW.exchange_rate_expires_at, NEW.expires_at,
                  NEW.idempotency_key_digest, NEW.creation_request_digest) THEN
                RAISE EXCEPTION 'orders_order_snapshot_immutable' USING ERRCODE = '40001';
              END IF;
            END IF;

            IF TG_OP = 'DELETE' THEN
              RETURN OLD;
            END IF;
            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_orders_order_immutable ON orders_orders;
          CREATE TRIGGER trg_orders_order_immutable
            BEFORE UPDATE OR DELETE ON orders_orders
            FOR EACH ROW EXECUTE FUNCTION orders_order_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_orders_order_immutable ON orders_orders;"
        execute "DROP FUNCTION IF EXISTS orders_order_immutable();"
      end
    end
  end
end
