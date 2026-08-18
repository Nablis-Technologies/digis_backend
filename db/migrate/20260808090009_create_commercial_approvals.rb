class CreateCommercialApprovals < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_approvals, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.string :decision, null: false
      t.text :reason, null: false
      t.string :definition_digest, null: false, limit: 64
      t.uuid :actor_id, null: false
      t.timestamptz :decided_at, null: false
      t.string :idempotency_key_digest, null: false, limit: 64
      t.string :request_fingerprint, null: false, limit: 64
      t.timestamps
    end

    add_index :commercial_approvals, %i[target_type target_id decided_at],
              name: "idx_commercial_approvals_on_target_time"
    add_index :commercial_approvals, :idempotency_key_digest, unique: true
    add_check_constraint :commercial_approvals,
      "target_type IN ('Commercial::FeeScheduleVersion','Commercial::Assignment')",
      name: "commercial_approvals_target_type_check"
    add_check_constraint :commercial_approvals,
      "decision IN ('approved','rejected')",
      name: "commercial_approvals_decision_check"
    add_check_constraint :commercial_approvals,
      "definition_digest ~ '^[0-9a-f]{64}$' AND idempotency_key_digest ~ '^[0-9a-f]{64}$' " \
      "AND request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "commercial_approvals_request_evidence_check"

    add_foreign_key :commercial_approvals, :core_users,
                    column: :actor_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_approval_append_only()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            RAISE EXCEPTION 'commercial_approval_append_only' USING ERRCODE = '40001';
          END;
          $$;

          CREATE TRIGGER trg_commercial_approval_append_only
          BEFORE UPDATE OR DELETE ON commercial_approvals
          FOR EACH ROW EXECUTE FUNCTION commercial_approval_append_only();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_commercial_approval_append_only ON commercial_approvals;"
        execute "DROP FUNCTION IF EXISTS commercial_approval_append_only();"
      end
    end
  end
end
