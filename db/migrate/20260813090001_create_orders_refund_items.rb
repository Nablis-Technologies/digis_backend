# frozen_string_literal: true

# Item rows are intentionally separate from the provider refund obligation.
# They let the later refund command revoke one package/date or add-on unit
# while keeping the provider-facing amount immutable and auditable.
class CreateOrdersRefundItems < ActiveRecord::Migration[8.1]
  def up
    create_table :orders_refund_items, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :refund_id, null: false
      t.uuid :order_item_id, null: false
      t.uuid :ticket_id
      t.uuid :event_date_id
      t.uuid :event_date_change_id
      t.integer :quantity, null: false
      t.bigint :subtotal_minor, null: false
      t.bigint :amount_minor, null: false
      t.boolean :restock, null: false, default: false
      t.string :reason

      t.timestamps
    end

    add_index :orders_refund_items, :refund_id
    add_index :orders_refund_items, :order_item_id
    add_index :orders_refund_items, %i[ticket_id event_date_id]
    add_index :orders_refund_items, :event_date_change_id

    add_check_constraint :orders_refund_items,
      "quantity > 0 AND subtotal_minor >= 0 AND amount_minor > 0",
      name: "refund_items_positive_amounts"

    add_foreign_key :orders_refund_items, :orders_refunds,
                    column: :refund_id, on_delete: :restrict
    add_foreign_key :orders_refund_items, :orders_order_items,
                    column: :order_item_id, on_delete: :restrict
    add_foreign_key :orders_refund_items, :ticketing_tickets,
                    column: :ticket_id, on_delete: :restrict
    add_foreign_key :orders_refund_items, :events_event_dates,
                    column: :event_date_id, on_delete: :restrict
    add_foreign_key :orders_refund_items, :events_event_date_changes,
                    column: :event_date_change_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION orders_refund_item_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        refund_order_id uuid;
        refund_event_id uuid;
        refund_type text;
        item_order_id uuid;
        item_product_id uuid;
        item_product_type text;
        ticket_order_item_id uuid;
        ticket_event_id uuid;
        ticket_product_id uuid;
        date_event_id uuid;
        change_event_id uuid;
        change_date_id uuid;
      BEGIN
        SELECT payments.order_id, orders.event_id, refunds.type
          INTO refund_order_id, refund_event_id, refund_type
        FROM orders_refunds AS refunds
        JOIN orders_payments AS payments ON payments.id = refunds.payment_id
        JOIN orders_orders AS orders ON orders.id = payments.order_id
        WHERE refunds.id = NEW.refund_id;

        SELECT order_id, event_product_id, type_snapshot
          INTO item_order_id, item_product_id, item_product_type
        FROM orders_order_items
        WHERE id = NEW.order_item_id;

        IF item_order_id IS DISTINCT FROM refund_order_id THEN
          RAISE EXCEPTION 'orders_refund_item_order_scope' USING ERRCODE = '23514';
        END IF;

        IF NEW.ticket_id IS NOT NULL THEN
          SELECT order_item_id, event_id, event_product_id
            INTO ticket_order_item_id, ticket_event_id, ticket_product_id
          FROM ticketing_tickets
          WHERE id = NEW.ticket_id;

          IF ticket_order_item_id IS DISTINCT FROM NEW.order_item_id OR
             ticket_event_id IS DISTINCT FROM refund_event_id OR
             ticket_product_id IS DISTINCT FROM item_product_id OR
             item_product_type IS DISTINCT FROM 'ticket' OR
             NEW.quantity IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION 'orders_refund_item_ticket_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.event_date_id IS NOT NULL THEN
          IF NEW.ticket_id IS NULL THEN
            RAISE EXCEPTION 'orders_refund_item_date_requires_ticket' USING ERRCODE = '23514';
          END IF;

          SELECT event_id INTO date_event_id
          FROM events_event_dates
          WHERE id = NEW.event_date_id;

          IF date_event_id IS DISTINCT FROM refund_event_id OR NOT EXISTS (
            SELECT 1
            FROM catalog_product_accesses
            WHERE event_product_id = item_product_id
              AND event_date_id = NEW.event_date_id
          ) OR NOT EXISTS (
            SELECT 1
            FROM catalog_product_date_allocations
            WHERE event_product_id = item_product_id
              AND event_date_id = NEW.event_date_id
          ) THEN
            RAISE EXCEPTION 'orders_refund_item_date_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.event_date_change_id IS NOT NULL THEN
          SELECT event_id, event_date_id
            INTO change_event_id, change_date_id
          FROM events_event_date_changes
          WHERE id = NEW.event_date_change_id;

          IF change_event_id IS DISTINCT FROM refund_event_id OR
             change_date_id IS DISTINCT FROM NEW.event_date_id THEN
            RAISE EXCEPTION 'orders_refund_item_date_change_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF refund_type = 'payment_reversal' THEN
          RAISE EXCEPTION 'orders_payment_reversal_cannot_have_items' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      DROP TRIGGER IF EXISTS trg_orders_refund_item_integrity ON orders_refund_items;
      CREATE TRIGGER trg_orders_refund_item_integrity
        BEFORE INSERT OR UPDATE ON orders_refund_items
        FOR EACH ROW EXECUTE FUNCTION orders_refund_item_integrity();

      CREATE OR REPLACE FUNCTION orders_refund_item_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'orders_refund_item_immutable' USING ERRCODE = '40001';
      END;
      $$;

      DROP TRIGGER IF EXISTS trg_orders_refund_item_immutable ON orders_refund_items;
      CREATE TRIGGER trg_orders_refund_item_immutable
        BEFORE UPDATE OR DELETE ON orders_refund_items
        FOR EACH ROW EXECUTE FUNCTION orders_refund_item_immutable();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_orders_refund_item_integrity ON orders_refund_items;"
    execute "DROP TRIGGER IF EXISTS trg_orders_refund_item_immutable ON orders_refund_items;"
    execute "DROP FUNCTION IF EXISTS orders_refund_item_immutable();"
    execute "DROP FUNCTION IF EXISTS orders_refund_item_integrity();"
    drop_table :orders_refund_items
  end
end
