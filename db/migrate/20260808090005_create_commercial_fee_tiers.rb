# frozen_string_literal: true

class CreateCommercialFeeTiers < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_fee_tiers, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_component_id, null: false
      t.integer :position, null: false
      t.string :metric_type, null: false
      t.string :window_type, null: false
      t.string :currency, limit: 3
      t.bigint :starts_at_value, null: false
      t.integer :rate_bps
      t.bigint :fixed_amount_minor
      t.bigint :minimum_minor
      t.bigint :maximum_minor

      t.timestamps
    end

    add_index :commercial_fee_tiers, %i[fee_component_id position], unique: true,
              name: "index_commercial_fee_tiers_on_component_and_position"
    add_index :commercial_fee_tiers, %i[metric_type window_type currency]
    add_check_constraint :commercial_fee_tiers,
      "position > 0",
      name: "commercial_fee_tiers_position_check"
    add_check_constraint :commercial_fee_tiers,
      "metric_type IN ('accepted_paid_units','accepted_gross')",
      name: "commercial_fee_tiers_metric_type_check"
    add_check_constraint :commercial_fee_tiers,
      "window_type IN ('event','calendar_month','calendar_quarter','calendar_year','agreement_term')",
      name: "commercial_fee_tiers_window_type_check"
    add_check_constraint :commercial_fee_tiers,
      "starts_at_value >= 0",
      name: "commercial_fee_tiers_threshold_check"
    add_check_constraint :commercial_fee_tiers,
      "metric_type <> 'accepted_gross' OR currency IS NOT NULL",
      name: "commercial_fee_tiers_gross_currency_check"
    add_check_constraint :commercial_fee_tiers,
      "currency IS NULL OR currency ~ '^[A-Z]{3}$'",
      name: "commercial_fee_tiers_currency_check"
    add_check_constraint :commercial_fee_tiers,
      "rate_bps IS NULL OR rate_bps BETWEEN 0 AND 10000",
      name: "commercial_fee_tiers_rate_check"
    add_check_constraint :commercial_fee_tiers,
      "fixed_amount_minor IS NULL OR fixed_amount_minor >= 0",
      name: "commercial_fee_tiers_fixed_amount_check"
    add_check_constraint :commercial_fee_tiers,
      "minimum_minor IS NULL OR minimum_minor >= 0",
      name: "commercial_fee_tiers_minimum_check"
    add_check_constraint :commercial_fee_tiers,
      "maximum_minor IS NULL OR maximum_minor >= 0",
      name: "commercial_fee_tiers_maximum_check"
    add_check_constraint :commercial_fee_tiers,
      "minimum_minor IS NULL OR maximum_minor IS NULL OR maximum_minor >= minimum_minor",
      name: "commercial_fee_tiers_ordered_bounds_check"
    add_foreign_key :commercial_fee_tiers, :commercial_fee_components,
                    column: :fee_component_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_fee_tier_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            old_status text;
            new_status text;
          BEGIN
            IF TG_OP IN ('UPDATE','DELETE') THEN
              SELECT version.status INTO old_status
              FROM commercial_fee_components component
              JOIN commercial_fee_schedule_versions version
                ON version.id = component.fee_schedule_version_id
              WHERE component.id = OLD.fee_component_id;
            END IF;
            IF TG_OP IN ('INSERT','UPDATE') THEN
              SELECT version.status INTO new_status
              FROM commercial_fee_components component
              JOIN commercial_fee_schedule_versions version
                ON version.id = component.fee_schedule_version_id
              WHERE component.id = NEW.fee_component_id;
            END IF;

            IF old_status IN ('approved','scheduled','active','superseded','expired','terminated') OR
               new_status IN ('approved','scheduled','active','superseded','expired','terminated') THEN
              RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
            END IF;

            IF TG_OP = 'DELETE' THEN
              RETURN OLD;
            END IF;
            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_commercial_fee_tier_immutable
            ON commercial_fee_tiers;
          CREATE TRIGGER trg_commercial_fee_tier_immutable
            BEFORE INSERT OR UPDATE OR DELETE ON commercial_fee_tiers
            FOR EACH ROW EXECUTE FUNCTION commercial_fee_tier_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_commercial_fee_tier_immutable ON commercial_fee_tiers;"
        execute "DROP FUNCTION IF EXISTS commercial_fee_tier_immutable();"
      end
    end
  end
end
