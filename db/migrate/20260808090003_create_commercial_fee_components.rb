# frozen_string_literal: true

class CreateCommercialFeeComponents < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_fee_components, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_schedule_version_id, null: false
      t.string :component_type, null: false
      t.string :calculation_type, null: false
      t.string :charged_to, null: false, default: "buyer"
      t.boolean :organizer_payer_choice, null: false, default: false
      t.string :funded_by, null: false, default: "buyer"
      t.string :basis_type
      t.integer :rate_bps
      t.string :refund_policy, null: false, default: "nonrefundable"
      t.string :offset_component_type
      t.uuid :event_product_id
      t.string :product_type
      t.string :sale_context
      t.string :provider
      t.string :payment_method
      t.string :sales_channel
      t.string :currency, limit: 3
      t.string :label, null: false

      t.timestamps
    end

    add_index :commercial_fee_components, :fee_schedule_version_id
    add_index :commercial_fee_components, :event_product_id
    add_index :commercial_fee_components, %i[component_type product_type sale_context]
    add_index :commercial_fee_components, %i[provider payment_method sales_channel currency]
    add_check_constraint :commercial_fee_components,
      "component_type IN ('platform_commission','buyer_service_fee','processing_cost_recovery','platform_subsidy','resale_platform_fee')",
      name: "commercial_fee_components_component_type_check"
    add_check_constraint :commercial_fee_components,
      "calculation_type IN ('explicit_zero','percentage','fixed','blended','tiered')",
      name: "commercial_fee_components_calculation_type_check"
    add_check_constraint :commercial_fee_components,
      "charged_to IN ('buyer','organizer')",
      name: "commercial_fee_components_charged_to_check"
    add_check_constraint :commercial_fee_components,
      "funded_by IN ('buyer','organizer','platform')",
      name: "commercial_fee_components_funded_by_check"
    add_check_constraint :commercial_fee_components,
      "refund_policy IN ('refundable','event_cancellation_only','nonrefundable')",
      name: "commercial_fee_components_refund_policy_check"
    add_check_constraint :commercial_fee_components,
      "sale_context IS NULL OR sale_context IN ('primary','resale')",
      name: "commercial_fee_components_sale_context_check"
    add_check_constraint :commercial_fee_components,
      "product_type IS NULL OR product_type IN ('ticket','parking','merchandise','food','donation','digital_addon','other')",
      name: "commercial_fee_components_product_type_check"
    add_check_constraint :commercial_fee_components,
      "provider IS NULL OR provider IN ('chapa','stripe')",
      name: "commercial_fee_components_provider_check"
    add_check_constraint :commercial_fee_components,
      "payment_method IS NULL OR payment_method IN ('telebirr','card','bank')",
      name: "commercial_fee_components_payment_method_check"
    add_check_constraint :commercial_fee_components,
      "sales_channel IS NULL OR sales_channel IN ('online','walk_up','resale')",
      name: "commercial_fee_components_sales_channel_check"
    add_check_constraint :commercial_fee_components,
      "currency IS NULL OR currency ~ '^[A-Z]{3}$'",
      name: "commercial_fee_components_currency_check"
    add_check_constraint :commercial_fee_components,
      "rate_bps IS NULL OR rate_bps BETWEEN 0 AND 10000",
      name: "commercial_fee_components_rate_check"
    add_check_constraint :commercial_fee_components,
      "(calculation_type IN ('percentage','blended') AND rate_bps IS NOT NULL) OR " \
      "(calculation_type IN ('explicit_zero','fixed','tiered') AND rate_bps IS NULL)",
      name: "commercial_fee_components_rate_shape_check"
    add_check_constraint :commercial_fee_components,
      "(calculation_type IN ('percentage','blended','tiered') AND basis_type IS NOT NULL) OR " \
      "(calculation_type IN ('explicit_zero','fixed') AND basis_type IS NULL)",
      name: "commercial_fee_components_basis_shape_check"
    add_check_constraint :commercial_fee_components,
      "(component_type = 'platform_subsidy' AND funded_by = 'platform' AND offset_component_type IS NOT NULL) OR " \
      "(component_type <> 'platform_subsidy' AND funded_by <> 'platform' AND offset_component_type IS NULL)",
      name: "commercial_fee_components_subsidy_shape_check"
    add_check_constraint :commercial_fee_components,
      "offset_component_type IS NULL OR offset_component_type IN ('platform_commission','buyer_service_fee','processing_cost_recovery','resale_platform_fee')",
      name: "commercial_fee_components_offset_type_check"
    add_foreign_key :commercial_fee_components, :commercial_fee_schedule_versions,
                    column: :fee_schedule_version_id, on_delete: :restrict
    add_foreign_key :commercial_fee_components, :catalog_event_products,
                    column: :event_product_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_fee_component_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            old_status text;
            new_status text;
          BEGIN
            IF TG_OP IN ('UPDATE','DELETE') THEN
              SELECT status INTO old_status
              FROM commercial_fee_schedule_versions
              WHERE id = OLD.fee_schedule_version_id;
            END IF;
            IF TG_OP IN ('INSERT','UPDATE') THEN
              SELECT status INTO new_status
              FROM commercial_fee_schedule_versions
              WHERE id = NEW.fee_schedule_version_id;
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

          DROP TRIGGER IF EXISTS trg_commercial_fee_component_immutable
            ON commercial_fee_components;
          CREATE TRIGGER trg_commercial_fee_component_immutable
            BEFORE INSERT OR UPDATE OR DELETE ON commercial_fee_components
            FOR EACH ROW EXECUTE FUNCTION commercial_fee_component_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_commercial_fee_component_immutable ON commercial_fee_components;"
        execute "DROP FUNCTION IF EXISTS commercial_fee_component_immutable();"
      end
    end
  end
end
