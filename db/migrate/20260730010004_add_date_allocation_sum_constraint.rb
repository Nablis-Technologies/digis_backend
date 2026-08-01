# frozen_string_literal: true

# Deferred DB constraint enforcing that a product's date allocations sum to
# exactly 10,000 basis points at commit. The application service
# (Catalog::DateAllocations::Replace) validates the same invariant for
# actionable errors, but this trigger guarantees it at the storage layer for
# any writer, including bulk SQL.
class AddDateAllocationSumConstraint < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION catalog_date_allocations_sum_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF (
          SELECT COALESCE(SUM(allocation_basis_points), 0)
          FROM catalog_product_date_allocations
          WHERE event_product_id = NEW.event_product_id
        ) <> 10000 THEN
          RAISE EXCEPTION 'date allocations must sum to 10000 basis points for product %',
            NEW.event_product_id USING ERRCODE = '23514';
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
        AFTER INSERT OR UPDATE OF allocation_basis_points, event_product_id
        ON catalog_product_date_allocations
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION catalog_date_allocations_sum_guard();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_date_allocation_sum_check ON catalog_product_date_allocations;"
    execute "DROP FUNCTION IF EXISTS catalog_date_allocations_sum_guard();"
  end
end
