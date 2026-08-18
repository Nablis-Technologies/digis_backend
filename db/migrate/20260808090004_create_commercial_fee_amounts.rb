# frozen_string_literal: true

class CreateCommercialFeeAmounts < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_fee_amounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_component_id, null: false
      t.string :currency, null: false, limit: 3
      t.bigint :fixed_amount_minor
      t.bigint :minimum_minor
      t.bigint :maximum_minor

      t.timestamps
    end

    add_index :commercial_fee_amounts, %i[fee_component_id currency], unique: true,
              name: "index_commercial_fee_amounts_on_component_and_currency"
    add_check_constraint :commercial_fee_amounts,
      "currency ~ '^[A-Z]{3}$'",
      name: "commercial_fee_amounts_currency_check"
    add_check_constraint :commercial_fee_amounts,
      "fixed_amount_minor IS NULL OR fixed_amount_minor >= 0",
      name: "commercial_fee_amounts_fixed_amount_check"
    add_check_constraint :commercial_fee_amounts,
      "minimum_minor IS NULL OR minimum_minor >= 0",
      name: "commercial_fee_amounts_minimum_check"
    add_check_constraint :commercial_fee_amounts,
      "maximum_minor IS NULL OR maximum_minor >= 0",
      name: "commercial_fee_amounts_maximum_check"
    add_check_constraint :commercial_fee_amounts,
      "minimum_minor IS NULL OR maximum_minor IS NULL OR maximum_minor >= minimum_minor",
      name: "commercial_fee_amounts_ordered_bounds_check"
    add_foreign_key :commercial_fee_amounts, :commercial_fee_components,
                    column: :fee_component_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_fee_amount_immutable()
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

          DROP TRIGGER IF EXISTS trg_commercial_fee_amount_immutable
            ON commercial_fee_amounts;
          CREATE TRIGGER trg_commercial_fee_amount_immutable
            BEFORE INSERT OR UPDATE OR DELETE ON commercial_fee_amounts
            FOR EACH ROW EXECUTE FUNCTION commercial_fee_amount_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_commercial_fee_amount_immutable ON commercial_fee_amounts;"
        execute "DROP FUNCTION IF EXISTS commercial_fee_amount_immutable();"
      end
    end
  end
end
