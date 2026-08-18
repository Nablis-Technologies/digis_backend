# frozen_string_literal: true

# Deferred DB constraint enforcing that a multi-date product's date allocations
# cover every granted date and sum to exactly 10,000 basis points at commit.
# The application services validate the same invariant for actionable errors,
# while these triggers guarantee it at the storage layer for any writer,
# including bulk SQL that changes either side of the access/allocation pair.
class AddDateAllocationSumConstraint < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION catalog_date_allocations_sum_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        product_id uuid;
        granted_date_count bigint;
        allocated_date_count bigint;
        allocation_total bigint;
      BEGIN
        product_id := CASE TG_TABLE_NAME
          WHEN 'catalog_event_products' THEN COALESCE(NEW.id, OLD.id)
          ELSE COALESCE(NEW.event_product_id, OLD.event_product_id)
        END;

        SELECT COUNT(DISTINCT event_date_id)
          INTO granted_date_count
        FROM catalog_product_accesses
        WHERE event_product_id = product_id;

        SELECT COUNT(DISTINCT event_date_id), COALESCE(SUM(allocation_basis_points), 0)
          INTO allocated_date_count, allocation_total
        FROM catalog_product_date_allocations
        WHERE event_product_id = product_id;

        IF EXISTS (
          SELECT 1
          FROM catalog_product_date_allocations AS allocations
          WHERE allocations.event_product_id = product_id
            AND NOT EXISTS (
              SELECT 1
              FROM catalog_product_accesses AS accesses
              WHERE accesses.event_product_id = allocations.event_product_id
                AND accesses.event_date_id = allocations.event_date_id
            )
        ) THEN
          RAISE EXCEPTION 'date allocation requires a product access grant for product %', product_id
            USING ERRCODE = '23514';
        END IF;

        IF allocated_date_count > 0 AND
           (allocation_total <> 10000 OR
            (granted_date_count > 1 AND
           EXISTS (
             SELECT 1
             FROM catalog_event_products
             WHERE id = product_id
               AND schedule_change_refund_policy = 'full_or_partial'
           ) AND
           allocated_date_count <> granted_date_count)) THEN
          RAISE EXCEPTION 'multi-date product allocations must cover all granted dates and sum to 10000 for product %',
            product_id USING ERRCODE = '23514';
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL

    # A deferred constraint trigger fires at COMMIT, so an intermediate state
    # (e.g. delete-all-then-insert inside a Replace transaction) never trips it.
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_date_allocation_sum_check ON catalog_product_date_allocations;
      CREATE CONSTRAINT TRIGGER trg_date_allocation_sum_check
        AFTER INSERT OR UPDATE OF allocation_basis_points, event_product_id OR DELETE
        ON catalog_product_date_allocations
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION catalog_date_allocations_sum_guard();

      DROP TRIGGER IF EXISTS trg_date_access_allocation_check ON catalog_product_accesses;
      CREATE CONSTRAINT TRIGGER trg_date_access_allocation_check
        AFTER INSERT OR UPDATE OF event_product_id, event_date_id OR DELETE
        ON catalog_product_accesses
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION catalog_date_allocations_sum_guard();

      DROP TRIGGER IF EXISTS trg_product_refund_policy_allocation_check ON catalog_event_products;
      CREATE CONSTRAINT TRIGGER trg_product_refund_policy_allocation_check
        AFTER UPDATE OF schedule_change_refund_policy ON catalog_event_products
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION catalog_date_allocations_sum_guard();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_date_allocation_sum_check ON catalog_product_date_allocations;"
    execute "DROP TRIGGER IF EXISTS trg_date_access_allocation_check ON catalog_product_accesses;"
    execute "DROP TRIGGER IF EXISTS trg_product_refund_policy_allocation_check ON catalog_event_products;"
    execute "DROP FUNCTION IF EXISTS catalog_date_allocations_sum_guard();"
  end
end
