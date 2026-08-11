class CreateCommercialVolumeUsages < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_volume_usages, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_component_id, null: false
      t.uuid :organization_id, null: false
      t.uuid :event_id
      t.uuid :order_id, null: false
      t.string :metric_type, null: false
      t.string :window_type, null: false
      t.timestamptz :window_start_at, null: false
      t.timestamptz :window_end_at
      t.string :currency, limit: 3
      t.bigint :value, null: false
      t.timestamptz :accepted_at, null: false

      t.timestamps
    end

    add_index :commercial_volume_usages, :order_id,
              name: "idx_volume_usages_on_order"
    add_index :commercial_volume_usages, %i[fee_component_id organization_id],
              name: "idx_volume_usages_on_component_scope"
    add_index :commercial_volume_usages,
              %i[metric_type window_type window_start_at window_end_at currency],
              name: "idx_volume_usages_on_dimension"
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE UNIQUE INDEX idx_volume_usages_on_order_dimension
          ON commercial_volume_usages (
            order_id, fee_component_id, metric_type, window_type, currency,
            window_start_at, window_end_at
          ) NULLS NOT DISTINCT;
        SQL
      end
      dir.down { execute "DROP INDEX IF EXISTS idx_volume_usages_on_order_dimension;" }
    end

    add_check_constraint :commercial_volume_usages,
      "metric_type IN ('accepted_paid_units','accepted_gross')",
      name: "commercial_volume_usages_metric_type_check"
    add_check_constraint :commercial_volume_usages,
      "window_type IN ('event','calendar_month','calendar_quarter','calendar_year','agreement_term')",
      name: "commercial_volume_usages_window_type_check"
    add_check_constraint :commercial_volume_usages,
      "window_type <> 'event' OR event_id IS NOT NULL",
      name: "commercial_volume_usages_event_window_check"
    add_check_constraint :commercial_volume_usages,
      "((metric_type = 'accepted_gross' AND currency IS NOT NULL AND currency ~ '^[A-Z]{3}') OR " \
      "(metric_type = 'accepted_paid_units' AND currency IS NULL))",
      name: "commercial_volume_usages_currency_check"
    add_check_constraint :commercial_volume_usages,
      "window_end_at IS NULL OR window_end_at > window_start_at",
      name: "commercial_volume_usages_window_bounds_check"
    add_check_constraint :commercial_volume_usages,
      "value >= 0",
      name: "commercial_volume_usages_value_check"

    add_foreign_key :commercial_volume_usages, :commercial_fee_components,
                    column: :fee_component_id, on_delete: :restrict
    add_foreign_key :commercial_volume_usages, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :commercial_volume_usages, :events_events,
                    column: :event_id, on_delete: :restrict
    add_foreign_key :commercial_volume_usages, :orders_orders,
                    column: :order_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_volume_usage_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            order_event_id uuid;
            order_organization_id uuid;
            order_currency text;
            order_status text;
            component_event_product_id uuid;
            component_event_id uuid;
          BEGIN
            IF TG_OP <> 'INSERT' THEN
              RAISE EXCEPTION 'commercial_volume_usage_immutable' USING ERRCODE = '40001';
            END IF;

            SELECT orders.event_id, events.organization_id, orders.settlement_currency, orders.status
              INTO order_event_id, order_organization_id, order_currency, order_status
            FROM orders_orders orders
            JOIN events_events events ON events.id = orders.event_id
            WHERE orders.id = NEW.order_id;

            IF order_status NOT IN ('paid','fulfilled','partially_refunded','refunded') THEN
              RAISE EXCEPTION 'commercial_volume_usage_order_status' USING ERRCODE = '23514';
            END IF;

            IF order_organization_id IS DISTINCT FROM NEW.organization_id THEN
              RAISE EXCEPTION 'commercial_volume_usage_organization_scope' USING ERRCODE = '23514';
            END IF;

            IF NEW.window_type = 'event' AND NEW.event_id IS DISTINCT FROM order_event_id THEN
              RAISE EXCEPTION 'commercial_volume_usage_event_scope' USING ERRCODE = '23514';
            END IF;

            IF NEW.event_id IS NOT NULL AND NEW.event_id IS DISTINCT FROM order_event_id THEN
              RAISE EXCEPTION 'commercial_volume_usage_event_scope' USING ERRCODE = '23514';
            END IF;

            SELECT event_product_id INTO component_event_product_id
            FROM commercial_fee_components
            WHERE id = NEW.fee_component_id;

            IF component_event_product_id IS NOT NULL THEN
              SELECT event_id INTO component_event_id
              FROM catalog_event_products
              WHERE id = component_event_product_id;

              IF component_event_id IS DISTINCT FROM order_event_id THEN
                RAISE EXCEPTION 'commercial_volume_usage_component_scope' USING ERRCODE = '23514';
              END IF;
            END IF;

            IF NEW.metric_type = 'accepted_gross' AND NEW.currency IS DISTINCT FROM order_currency THEN
              RAISE EXCEPTION 'commercial_volume_usage_currency_scope' USING ERRCODE = '23514';
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_commercial_volume_usage_integrity
            ON commercial_volume_usages;
          CREATE TRIGGER trg_commercial_volume_usage_integrity
            BEFORE INSERT OR UPDATE OR DELETE ON commercial_volume_usages
            FOR EACH ROW EXECUTE FUNCTION commercial_volume_usage_integrity();
        SQL
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS trg_commercial_volume_usage_integrity
            ON commercial_volume_usages;
          DROP FUNCTION IF EXISTS commercial_volume_usage_integrity();
        SQL
      end
    end
  end
end
