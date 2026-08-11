class CreateCommercialEventPayerSelections < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_event_payer_selections, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :fee_component_id, null: false
      t.string :charged_to, null: false
      t.uuid :selected_by_id
      t.timestamptz :selected_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.string :idempotency_key_digest, null: false, limit: 64
      t.string :request_fingerprint, null: false, limit: 64

      t.timestamps
    end

    add_index :commercial_event_payer_selections, %i[event_id fee_component_id],
              unique: true,
              name: "idx_event_payer_selections_on_event_component"
    add_index :commercial_event_payer_selections, :selected_by_id,
              name: "idx_event_payer_selections_on_actor"

    add_check_constraint :commercial_event_payer_selections,
      "charged_to IN ('buyer','organizer')",
      name: "commercial_event_payer_selections_payer_check"
    add_check_constraint :commercial_event_payer_selections,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "commercial_event_payer_selections_request_evidence_check"

    add_foreign_key :commercial_event_payer_selections, :events_events,
                    column: :event_id, on_delete: :restrict
    add_foreign_key :commercial_event_payer_selections, :commercial_fee_components,
                    column: :fee_component_id, on_delete: :restrict
    add_foreign_key :commercial_event_payer_selections, :core_users,
                    column: :selected_by_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_event_payer_selection_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            component_event_product_id uuid;
            component_event_id uuid;
            component_default_payer text;
            component_allows_choice boolean;
          BEGIN
            SELECT event_product_id, charged_to, organizer_payer_choice
              INTO component_event_product_id, component_default_payer, component_allows_choice
            FROM commercial_fee_components
            WHERE id = NEW.fee_component_id;

            IF component_event_product_id IS NOT NULL THEN
              SELECT event_id INTO component_event_id
              FROM catalog_event_products
              WHERE id = component_event_product_id;

              IF component_event_id IS DISTINCT FROM NEW.event_id THEN
                RAISE EXCEPTION 'commercial_event_payer_selection_event_scope' USING ERRCODE = '23514';
              END IF;
            END IF;

            IF NEW.charged_to IS DISTINCT FROM component_default_payer AND NOT component_allows_choice THEN
              RAISE EXCEPTION 'commercial_event_payer_selection_forbidden' USING ERRCODE = '23514';
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_commercial_event_payer_selection_integrity
            ON commercial_event_payer_selections;
          CREATE TRIGGER trg_commercial_event_payer_selection_integrity
            BEFORE INSERT OR UPDATE ON commercial_event_payer_selections
            FOR EACH ROW EXECUTE FUNCTION commercial_event_payer_selection_integrity();
        SQL
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS trg_commercial_event_payer_selection_integrity
            ON commercial_event_payer_selections;
          DROP FUNCTION IF EXISTS commercial_event_payer_selection_integrity();
        SQL
      end
    end
  end
end
