class CreateCommercialSimulations < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_simulations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_schedule_version_id, null: false
      t.uuid :assignment_id
      t.string :definition_digest, null: false, limit: 64
      t.string :scenario_digest, null: false, limit: 64
      t.jsonb :normalized_outputs, null: false, default: {}
      t.jsonb :warnings, null: false, default: []
      t.boolean :passed, null: false, default: false
      t.uuid :run_by_id, null: false
      t.timestamptz :run_at, null: false
      t.string :idempotency_key_digest, null: false, limit: 64
      t.string :request_fingerprint, null: false, limit: 64
      t.timestamps
    end

    add_index :commercial_simulations, %i[fee_schedule_version_id definition_digest run_at],
              name: "idx_commercial_simulations_on_version_digest_time"
    add_index :commercial_simulations, :assignment_id
    add_index :commercial_simulations, :idempotency_key_digest, unique: true
    add_check_constraint :commercial_simulations,
      "definition_digest ~ '^[0-9a-f]{64}$' AND scenario_digest ~ '^[0-9a-f]{64}$'",
      name: "commercial_simulations_digest_check"
    add_check_constraint :commercial_simulations,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "commercial_simulations_request_evidence_check"
    add_check_constraint :commercial_simulations,
      "jsonb_typeof(normalized_outputs) = 'object' AND jsonb_typeof(warnings) = 'array'",
      name: "commercial_simulations_payload_shape_check"

    add_foreign_key :commercial_simulations, :commercial_fee_schedule_versions,
                    column: :fee_schedule_version_id, on_delete: :restrict
    add_foreign_key :commercial_simulations, :commercial_assignments,
                    column: :assignment_id, on_delete: :restrict
    add_foreign_key :commercial_simulations, :core_users,
                    column: :run_by_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_simulation_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            RAISE EXCEPTION 'commercial_simulation_immutable' USING ERRCODE = '40001';
          END;
          $$;

          CREATE TRIGGER trg_commercial_simulation_immutable
          BEFORE UPDATE OR DELETE ON commercial_simulations
          FOR EACH ROW EXECUTE FUNCTION commercial_simulation_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_commercial_simulation_immutable ON commercial_simulations;"
        execute "DROP FUNCTION IF EXISTS commercial_simulation_immutable();"
      end
    end
  end
end
