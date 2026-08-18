# frozen_string_literal: true

# Refund adjustment rows preserve the signed buyer-side portions of the
# original order snapshot. The deferred reconciliation trigger allows a
# parent refund, item rows, and allocation rows to be assembled in any order,
# then validates the complete immutable shape at transaction commit.
class CreateOrdersRefundAdjustmentAllocations < ActiveRecord::Migration[8.1]
  def up
    create_table :orders_refund_adjustment_allocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :refund_item_id, null: false
      t.uuid :order_adjustment_id, null: false
      t.bigint :amount_minor, null: false

      t.timestamps
    end

    add_index :orders_refund_adjustment_allocations,
              %i[refund_item_id order_adjustment_id],
              unique: true,
              name: "idx_refund_adjustment_once_per_item"
    add_index :orders_refund_adjustment_allocations, :order_adjustment_id

    add_check_constraint :orders_refund_adjustment_allocations,
      "amount_minor <> 0",
      name: "refund_adjustment_allocation_nonzero"

    add_foreign_key :orders_refund_adjustment_allocations, :orders_refund_items,
                    column: :refund_item_id, on_delete: :restrict
    add_foreign_key :orders_refund_adjustment_allocations, :orders_order_adjustments,
                    column: :order_adjustment_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION orders_refund_adjustment_allocation_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        refund_order_id uuid;
        adjustment_order_id uuid;
        adjustment_item_id uuid;
        adjustment_amount bigint;
      BEGIN
        SELECT payments.order_id
          INTO refund_order_id
        FROM orders_refund_items AS refund_items
        JOIN orders_refunds AS refunds ON refunds.id = refund_items.refund_id
        JOIN orders_payments AS payments ON payments.id = refunds.payment_id
        WHERE refund_items.id = NEW.refund_item_id;

        SELECT order_id, order_item_id, amount_minor
          INTO adjustment_order_id, adjustment_item_id, adjustment_amount
        FROM orders_order_adjustments
        WHERE id = NEW.order_adjustment_id;

        IF refund_order_id IS DISTINCT FROM adjustment_order_id OR
           (adjustment_item_id IS NOT NULL AND NOT EXISTS (
             SELECT 1
             FROM orders_refund_items AS refund_items
             WHERE refund_items.id = NEW.refund_item_id
               AND refund_items.order_item_id = adjustment_item_id
           )) OR
           adjustment_amount IS NULL OR
           adjustment_amount = 0 OR
           (adjustment_amount < 0 AND NEW.amount_minor >= 0) OR
           (adjustment_amount > 0 AND NEW.amount_minor <= 0) THEN
          RAISE EXCEPTION 'orders_refund_adjustment_scope' USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM orders_order_adjustments
          WHERE id = NEW.order_adjustment_id
            AND (charged_to <> 'buyer' OR refund_policy = 'nonrefundable')
        ) THEN
          RAISE EXCEPTION 'orders_refund_adjustment_not_buyer_refundable'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION orders_refund_reconcile(refund_uuid uuid)
      RETURNS void
      LANGUAGE plpgsql
      AS $$
      DECLARE
        refund_type text;
        refund_amount bigint;
        item_amount bigint;
      BEGIN
        SELECT type, amount_minor
          INTO refund_type, refund_amount
        FROM orders_refunds
        WHERE id = refund_uuid;

        IF refund_type IS NULL THEN
          RETURN;
        END IF;

        IF refund_type = 'payment_reversal' AND EXISTS (
          SELECT 1 FROM orders_refund_items WHERE refund_id = refund_uuid
        ) THEN
          RAISE EXCEPTION 'orders_payment_reversal_cannot_have_items' USING ERRCODE = '23514';
        END IF;

        IF refund_type <> 'item_refund' THEN
          RETURN;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM orders_refund_items WHERE refund_id = refund_uuid
        ) THEN
          RAISE EXCEPTION 'orders_item_refund_requires_items' USING ERRCODE = '23514';
        END IF;

        SELECT COALESCE(SUM(amount_minor), 0)
          INTO item_amount
        FROM orders_refund_items
        WHERE refund_id = refund_uuid;

        IF item_amount IS DISTINCT FROM refund_amount THEN
          RAISE EXCEPTION 'orders_item_refund_amount_mismatch' USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM orders_refund_items AS refund_items
          WHERE refund_items.refund_id = refund_uuid
            AND refund_items.amount_minor IS DISTINCT FROM
                refund_items.subtotal_minor + COALESCE((
                  SELECT SUM(allocations.amount_minor)
                  FROM orders_refund_adjustment_allocations AS allocations
                  WHERE allocations.refund_item_id = refund_items.id
                ), 0)
        ) THEN
          RAISE EXCEPTION 'orders_refund_item_amount_mismatch' USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM orders_order_items AS order_items
          WHERE (
            SELECT COALESCE(SUM(refund_items.amount_minor), 0)
            FROM orders_refund_items AS refund_items
            JOIN orders_refunds AS refunds ON refunds.id = refund_items.refund_id
            WHERE refund_items.order_item_id = order_items.id
              AND refunds.status IN ('created', 'pending_funds', 'processing', 'succeeded')
          ) > order_items.total_minor
        ) THEN
          RAISE EXCEPTION 'orders_refund_item_value_exceeded' USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM orders_refund_items AS refund_items
          JOIN orders_refunds AS refunds ON refunds.id = refund_items.refund_id
          WHERE refunds.status IN ('created', 'pending_funds', 'processing', 'succeeded')
            AND refund_items.ticket_id IS NOT NULL
            AND refund_items.event_date_id IS NULL
          GROUP BY refund_items.ticket_id
          HAVING COUNT(*) > 1
        ) OR EXISTS (
          SELECT 1
          FROM orders_refund_items AS refund_items
          JOIN orders_refunds AS refunds ON refunds.id = refund_items.refund_id
          WHERE refunds.status IN ('created', 'pending_funds', 'processing', 'succeeded')
            AND refund_items.ticket_id IS NOT NULL
            AND refund_items.event_date_id IS NOT NULL
          GROUP BY refund_items.ticket_id, refund_items.event_date_id
          HAVING COUNT(*) > 1
        ) OR EXISTS (
          SELECT 1
          FROM orders_refund_items AS refund_items
          JOIN orders_refunds AS refunds ON refunds.id = refund_items.refund_id
          WHERE refunds.status IN ('created', 'pending_funds', 'processing', 'succeeded')
            AND refund_items.ticket_id IS NOT NULL
          GROUP BY refund_items.ticket_id
          HAVING COUNT(*) FILTER (WHERE refund_items.event_date_id IS NULL) > 0
             AND COUNT(*) FILTER (WHERE refund_items.event_date_id IS NOT NULL) > 0
        ) THEN
          RAISE EXCEPTION 'orders_refund_ticket_value_exceeded' USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM orders_order_adjustments AS adjustments
          WHERE (
            SELECT COALESCE(SUM(allocations.amount_minor), 0)
            FROM orders_refund_adjustment_allocations AS allocations
            JOIN orders_refund_items AS refund_items
              ON refund_items.id = allocations.refund_item_id
            JOIN orders_refunds AS refunds ON refunds.id = refund_items.refund_id
            WHERE allocations.order_adjustment_id = adjustments.id
              AND refunds.status IN ('created', 'pending_funds', 'processing', 'succeeded')
          ) < adjustments.amount_minor AND adjustments.amount_minor < 0
        ) OR EXISTS (
          SELECT 1
          FROM orders_order_adjustments AS adjustments
          WHERE (
            SELECT COALESCE(SUM(allocations.amount_minor), 0)
            FROM orders_refund_adjustment_allocations AS allocations
            JOIN orders_refund_items AS refund_items
              ON refund_items.id = allocations.refund_item_id
            JOIN orders_refunds AS refunds ON refunds.id = refund_items.refund_id
            WHERE allocations.order_adjustment_id = adjustments.id
              AND refunds.status IN ('created', 'pending_funds', 'processing', 'succeeded')
          ) > adjustments.amount_minor AND adjustments.amount_minor > 0
        ) THEN
          RAISE EXCEPTION 'orders_refund_adjustment_value_exceeded' USING ERRCODE = '23514';
        END IF;
      END;
      $$;

      CREATE OR REPLACE FUNCTION orders_refund_reconcile_trigger()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_TABLE_NAME = 'orders_refunds' THEN
          PERFORM orders_refund_reconcile(NEW.id);
        ELSIF TG_TABLE_NAME = 'orders_refund_items' THEN
          PERFORM orders_refund_reconcile(COALESCE(NEW.refund_id, OLD.refund_id));
        ELSE
          PERFORM orders_refund_reconcile(
            COALESCE(
              (SELECT refund_id FROM orders_refund_items WHERE id = NEW.refund_item_id),
              (SELECT refund_id FROM orders_refund_items WHERE id = OLD.refund_item_id)
            )
          );
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$;

      DROP TRIGGER IF EXISTS trg_orders_refund_adjustment_allocation_integrity
        ON orders_refund_adjustment_allocations;
      CREATE TRIGGER trg_orders_refund_adjustment_allocation_integrity
        BEFORE INSERT OR UPDATE ON orders_refund_adjustment_allocations
        FOR EACH ROW EXECUTE FUNCTION orders_refund_adjustment_allocation_integrity();

      CREATE OR REPLACE FUNCTION orders_refund_adjustment_allocation_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'orders_refund_adjustment_allocation_immutable'
          USING ERRCODE = '40001';
      END;
      $$;

      DROP TRIGGER IF EXISTS trg_orders_refund_adjustment_allocation_immutable
        ON orders_refund_adjustment_allocations;
      CREATE TRIGGER trg_orders_refund_adjustment_allocation_immutable
        BEFORE UPDATE OR DELETE ON orders_refund_adjustment_allocations
        FOR EACH ROW EXECUTE FUNCTION orders_refund_adjustment_allocation_immutable();

      DROP TRIGGER IF EXISTS trg_orders_refund_reconcile ON orders_refunds;
      CREATE CONSTRAINT TRIGGER trg_orders_refund_reconcile
        AFTER INSERT OR UPDATE OF type, amount_minor, status ON orders_refunds
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION orders_refund_reconcile_trigger();

      DROP TRIGGER IF EXISTS trg_orders_refund_item_reconcile ON orders_refund_items;
      CREATE CONSTRAINT TRIGGER trg_orders_refund_item_reconcile
        AFTER INSERT OR UPDATE OR DELETE ON orders_refund_items
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION orders_refund_reconcile_trigger();

      DROP TRIGGER IF EXISTS trg_orders_refund_adjustment_reconcile
        ON orders_refund_adjustment_allocations;
      CREATE CONSTRAINT TRIGGER trg_orders_refund_adjustment_reconcile
        AFTER INSERT OR UPDATE OR DELETE ON orders_refund_adjustment_allocations
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION orders_refund_reconcile_trigger();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_orders_refund_adjustment_reconcile
        ON orders_refund_adjustment_allocations;
      DROP TRIGGER IF EXISTS trg_orders_refund_item_reconcile ON orders_refund_items;
      DROP TRIGGER IF EXISTS trg_orders_refund_reconcile ON orders_refunds;
      DROP TRIGGER IF EXISTS trg_orders_refund_adjustment_allocation_integrity
        ON orders_refund_adjustment_allocations;
      DROP TRIGGER IF EXISTS trg_orders_refund_adjustment_allocation_immutable
        ON orders_refund_adjustment_allocations;
      DROP FUNCTION IF EXISTS orders_refund_reconcile_trigger();
      DROP FUNCTION IF EXISTS orders_refund_reconcile(uuid);
      DROP FUNCTION IF EXISTS orders_refund_adjustment_allocation_integrity();
      DROP FUNCTION IF EXISTS orders_refund_adjustment_allocation_immutable();
    SQL

    drop_table :orders_refund_adjustment_allocations
  end
end
