class CreateCommercialVolumeCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_volume_counters, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_component_id, null: false
      t.uuid :organization_id, null: false
      t.uuid :event_id
      t.string :metric_type, null: false
      t.string :window_type, null: false
      t.timestamptz :window_start_at, null: false
      t.timestamptz :window_end_at
      t.string :currency, limit: 3
      t.bigint :value, null: false, default: 0
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :commercial_volume_counters, :fee_component_id,
              name: "idx_volume_counters_on_component"
    add_index :commercial_volume_counters, %i[organization_id event_id metric_type window_type],
              name: "idx_volume_counters_on_scope"
    add_index :commercial_volume_counters, %i[window_type window_start_at window_end_at],
              name: "idx_volume_counters_on_window"
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE UNIQUE INDEX idx_volume_counters_on_dimension
          ON commercial_volume_counters (
            fee_component_id, organization_id, event_id, metric_type, window_type,
            currency, window_start_at, window_end_at
          ) NULLS NOT DISTINCT;
        SQL
      end
      dir.down { execute "DROP INDEX IF EXISTS idx_volume_counters_on_dimension;" }
    end

    add_check_constraint :commercial_volume_counters,
      "metric_type IN ('accepted_paid_units','accepted_gross')",
      name: "commercial_volume_counters_metric_type_check"
    add_check_constraint :commercial_volume_counters,
      "window_type IN ('event','calendar_month','calendar_quarter','calendar_year','agreement_term')",
      name: "commercial_volume_counters_window_type_check"
    add_check_constraint :commercial_volume_counters,
      "window_type <> 'event' OR event_id IS NOT NULL",
      name: "commercial_volume_counters_event_window_check"
    add_check_constraint :commercial_volume_counters,
      "((metric_type = 'accepted_gross' AND currency IS NOT NULL AND currency ~ '^[A-Z]{3}') OR " \
      "(metric_type = 'accepted_paid_units' AND currency IS NULL))",
      name: "commercial_volume_counters_currency_check"
    add_check_constraint :commercial_volume_counters,
      "window_end_at IS NULL OR window_end_at > window_start_at",
      name: "commercial_volume_counters_window_bounds_check"
    add_check_constraint :commercial_volume_counters,
      "value >= 0 AND lock_version >= 0",
      name: "commercial_volume_counters_value_check"

    add_foreign_key :commercial_volume_counters, :commercial_fee_components,
                    column: :fee_component_id, on_delete: :restrict
    add_foreign_key :commercial_volume_counters, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :commercial_volume_counters, :events_events,
                    column: :event_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_volume_counter_scope()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            event_organization_id uuid;
            component_event_product_id uuid;
            component_event_id uuid;
          BEGIN
            IF NEW.event_id IS NULL THEN
              RETURN NEW;
            END IF;

            SELECT organization_id INTO event_organization_id
            FROM events_events
            WHERE id = NEW.event_id;

            IF event_organization_id IS DISTINCT FROM NEW.organization_id THEN
              RAISE EXCEPTION 'commercial_volume_counter_scope' USING ERRCODE = '23514';
            END IF;

            SELECT event_product_id INTO component_event_product_id
            FROM commercial_fee_components
            WHERE id = NEW.fee_component_id;

            IF component_event_product_id IS NOT NULL THEN
              SELECT event_id INTO component_event_id
              FROM catalog_event_products
              WHERE id = component_event_product_id;

              IF component_event_id IS DISTINCT FROM NEW.event_id THEN
                RAISE EXCEPTION 'commercial_volume_counter_component_scope' USING ERRCODE = '23514';
              END IF;
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_commercial_volume_counter_scope
            ON commercial_volume_counters;
          CREATE TRIGGER trg_commercial_volume_counter_scope
            BEFORE INSERT OR UPDATE ON commercial_volume_counters
            FOR EACH ROW EXECUTE FUNCTION commercial_volume_counter_scope();
        SQL
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS trg_commercial_volume_counter_scope
            ON commercial_volume_counters;
          DROP FUNCTION IF EXISTS commercial_volume_counter_scope();
        SQL
      end
    end
  end
end
