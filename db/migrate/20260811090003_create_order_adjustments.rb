# frozen_string_literal: true

class CreateOrderAdjustments < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_order_adjustments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :order_id, null: false
      t.uuid :order_item_id
      t.string :type, null: false
      t.string :label, null: false
      t.string :charged_to, null: false
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.string :refund_policy, null: false
      t.string :calculation_type
      t.string :basis_type
      t.bigint :basis_minor
      t.integer :rate_bps
      t.bigint :fixed_amount_minor
      t.bigint :minimum_minor
      t.bigint :maximum_minor
      t.string :funded_by
      t.string :source_type
      t.uuid :source_id
      t.jsonb :resolution_evidence

      t.timestamps
    end

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION orders_order_adjustment_evidence_valid(evidence jsonb)
          RETURNS boolean
          LANGUAGE plpgsql
          IMMUTABLE
          AS $$
          DECLARE
            evidence_key text;
          BEGIN
            IF evidence IS NULL THEN
              RETURN TRUE;
            END IF;
            IF jsonb_typeof(evidence) <> 'object' THEN
              RETURN FALSE;
            END IF;

            FOR evidence_key IN SELECT jsonb_object_keys(evidence) LOOP
              IF evidence_key NOT IN ('scope','tier','window','rounding','explanation') THEN
                RETURN FALSE;
              END IF;
            END LOOP;
            RETURN TRUE;
          END;
          $$;
        SQL
      end

      dir.down do
        execute "DROP FUNCTION IF EXISTS orders_order_adjustment_evidence_valid(jsonb);"
      end
    end

    add_check_constraint :orders_order_adjustments,
      "type IN ('discount','service_fee','platform_fee','processing_fee','subsidy','resale_platform_fee','tax','manual_adjustment')",
      name: "orders_adjustments_type_check"
    add_check_constraint :orders_order_adjustments,
      "charged_to IN ('buyer','organizer')",
      name: "orders_adjustments_charged_to_check"
    add_check_constraint :orders_order_adjustments,
      "refund_policy IN ('refundable','event_cancellation_only','nonrefundable')",
      name: "orders_adjustments_refund_policy_check"
    add_check_constraint :orders_order_adjustments,
      "currency ~ '^[A-Z]{3}$'",
      name: "orders_adjustments_currency_check"
    add_check_constraint :orders_order_adjustments,
      "((type IN ('discount','subsidy') AND amount_minor < 0) OR " \
      "(type IN ('service_fee','platform_fee','processing_fee','resale_platform_fee','tax') AND amount_minor >= 0) OR " \
      "type = 'manual_adjustment')",
      name: "orders_adjustments_amount_sign_check"
    add_check_constraint :orders_order_adjustments,
      "calculation_type IS NULL OR calculation_type IN ('explicit_zero','percentage','fixed','blended','tiered')",
      name: "orders_adjustments_calculation_check"
    add_check_constraint :orders_order_adjustments,
      "basis_type IS NULL OR basis_type IN ('item_face_value','item_net_value_after_organizer_promotion','eligible_order_subtotal','resale_acquisition_amount','accepted_paid_units','accepted_gross')",
      name: "orders_adjustments_basis_check"
    add_check_constraint :orders_order_adjustments,
      "funded_by IS NULL OR funded_by IN ('buyer','organizer','platform')",
      name: "orders_adjustments_funded_by_check"
    add_check_constraint :orders_order_adjustments,
      "source_type IS NULL OR source_type IN ('Catalog::Promotion','Commercial::FeeComponent')",
      name: "orders_adjustments_source_type_check"
    add_check_constraint :orders_order_adjustments,
      "(source_type IS NULL) = (source_id IS NULL)",
      name: "order_adjustment_source_pair"
    add_check_constraint :orders_order_adjustments,
      "basis_minor IS NULL OR basis_minor >= 0",
      name: "orders_adjustments_basis_amount_check"
    add_check_constraint :orders_order_adjustments,
      "calculation_type IS NULL OR calculation_type NOT IN ('explicit_zero','fixed') OR basis_minor IS NULL",
      name: "orders_adjustments_basis_amount_shape_check"
    add_check_constraint :orders_order_adjustments,
      "rate_bps IS NULL OR rate_bps BETWEEN 0 AND 10000",
      name: "orders_adjustments_rate_check"
    add_check_constraint :orders_order_adjustments,
      "(fixed_amount_minor IS NULL OR fixed_amount_minor >= 0) AND " \
      "(minimum_minor IS NULL OR minimum_minor >= 0) AND " \
      "(maximum_minor IS NULL OR maximum_minor >= 0) AND " \
      "(minimum_minor IS NULL OR maximum_minor IS NULL OR maximum_minor >= minimum_minor)",
      name: "orders_adjustments_bounds_check"
    add_check_constraint :orders_order_adjustments,
      "((calculation_type IN ('percentage','blended','tiered') AND basis_type IS NOT NULL) OR " \
      "(calculation_type IN ('explicit_zero','fixed') AND basis_type IS NULL) OR calculation_type IS NULL)",
      name: "orders_adjustments_basis_shape_check"
    add_check_constraint :orders_order_adjustments,
      "((calculation_type IN ('percentage','blended') AND rate_bps IS NOT NULL) OR " \
      "(calculation_type IN ('explicit_zero','fixed','tiered') AND rate_bps IS NULL) OR calculation_type IS NULL)",
      name: "orders_adjustments_rate_shape_check"
    add_check_constraint :orders_order_adjustments,
      "(calculation_type NOT IN ('fixed','blended') OR fixed_amount_minor IS NOT NULL) OR calculation_type IS NULL",
      name: "orders_adjustments_fixed_shape_check"
    add_check_constraint :orders_order_adjustments,
      "calculation_type <> 'explicit_zero' OR " \
      "(fixed_amount_minor IS NULL AND minimum_minor IS NULL AND maximum_minor IS NULL)",
      name: "orders_adjustments_explicit_zero_check"
    add_check_constraint :orders_order_adjustments,
      "(type NOT IN ('service_fee','platform_fee','processing_fee','subsidy','resale_platform_fee') OR " \
      "(calculation_type IS NOT NULL AND funded_by IS NOT NULL AND source_type IS NOT NULL AND source_id IS NOT NULL))",
      name: "orders_adjustments_commercial_shape_check"
    add_check_constraint :orders_order_adjustments,
      "(type <> 'subsidy' OR funded_by = 'platform') AND " \
      "(funded_by IS NULL OR type = 'subsidy' OR funded_by <> 'platform')",
      name: "orders_adjustments_subsidy_shape_check"
    add_check_constraint :orders_order_adjustments,
      "orders_order_adjustment_evidence_valid(resolution_evidence)",
      name: "orders_adjustments_evidence_check"

    add_index :orders_order_adjustments, :order_id, name: "idx_order_adjustments_on_order"
    add_index :orders_order_adjustments, :order_item_id, name: "idx_order_adjustments_on_order_item"
    add_index :orders_order_adjustments, %i[order_id type],
              name: "idx_order_adjustments_on_order_type"
    add_index :orders_order_adjustments, %i[source_type source_id],
              name: "idx_order_adjustments_on_source"

    add_foreign_key :orders_order_adjustments, :orders_orders,
                    column: :order_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          ALTER TABLE orders_order_adjustments
            ADD CONSTRAINT fk_order_adjustments_item_order
            FOREIGN KEY (order_item_id, order_id)
            REFERENCES orders_order_items (id, order_id)
            ON DELETE RESTRICT;

          CREATE OR REPLACE FUNCTION orders_order_adjustment_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            order_currency text;
          BEGIN
            SELECT charge_currency INTO order_currency
            FROM orders_orders
            WHERE id = NEW.order_id;

            IF order_currency IS DISTINCT FROM NEW.currency THEN
              RAISE EXCEPTION 'orders_order_adjustment_currency_scope' USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
          END;
          $$;

          CREATE OR REPLACE FUNCTION orders_order_adjustment_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            old_order_status text;
            new_order_status text;
          BEGIN
            IF TG_OP <> 'INSERT' THEN
              SELECT status INTO old_order_status FROM orders_orders WHERE id = OLD.order_id;
            END IF;
            IF TG_OP <> 'DELETE' THEN
              SELECT status INTO new_order_status FROM orders_orders WHERE id = NEW.order_id;
            END IF;

            IF old_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') OR
               new_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') THEN
              RAISE EXCEPTION 'orders_order_adjustment_immutable' USING ERRCODE = '40001';
            END IF;

            IF TG_OP = 'DELETE' THEN
              RETURN OLD;
            END IF;
            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_orders_order_adjustment_integrity ON orders_order_adjustments;
          CREATE TRIGGER trg_orders_order_adjustment_integrity
            BEFORE INSERT OR UPDATE ON orders_order_adjustments
            FOR EACH ROW EXECUTE FUNCTION orders_order_adjustment_integrity();

          DROP TRIGGER IF EXISTS trg_orders_order_adjustment_immutable ON orders_order_adjustments;
          CREATE TRIGGER trg_orders_order_adjustment_immutable
            BEFORE INSERT OR UPDATE OR DELETE ON orders_order_adjustments
            FOR EACH ROW EXECUTE FUNCTION orders_order_adjustment_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_orders_order_adjustment_immutable ON orders_order_adjustments;"
        execute "DROP TRIGGER IF EXISTS trg_orders_order_adjustment_integrity ON orders_order_adjustments;"
        execute "DROP FUNCTION IF EXISTS orders_order_adjustment_immutable();"
        execute "DROP FUNCTION IF EXISTS orders_order_adjustment_integrity();"
        execute "ALTER TABLE orders_order_adjustments DROP CONSTRAINT IF EXISTS fk_order_adjustments_item_order;"
      end
    end
  end
end
