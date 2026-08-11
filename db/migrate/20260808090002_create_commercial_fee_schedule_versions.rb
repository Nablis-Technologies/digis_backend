# frozen_string_literal: true

class CreateCommercialFeeScheduleVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_fee_schedule_versions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_schedule_id, null: false
      t.uuid :supersedes_version_id
      t.integer :version, null: false
      t.string :status, null: false, default: "draft"
      t.string :definition_digest, null: false, limit: 64
      t.uuid :legal_document_version_id
      t.string :acceptance_policy, null: false, default: "none"
      t.timestamptz :grandfather_until
      t.timestamptz :effective_from
      t.timestamptz :effective_until
      t.uuid :submitted_by_id
      t.timestamptz :submitted_at
      t.uuid :approved_by_id
      t.timestamptz :approved_at
      t.uuid :activated_by_id
      t.timestamptz :activated_at
      t.uuid :terminated_by_id
      t.timestamptz :terminated_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :commercial_fee_schedule_versions, %i[fee_schedule_id version], unique: true,
              name: "index_commercial_fee_versions_on_schedule_and_version"
    add_index :commercial_fee_schedule_versions, %i[fee_schedule_id status]
    add_index :commercial_fee_schedule_versions, %i[status effective_from effective_until]
    add_check_constraint :commercial_fee_schedule_versions,
      "version > 0",
      name: "commercial_fee_schedule_versions_version_check"
    add_check_constraint :commercial_fee_schedule_versions,
      "status IN ('draft','simulated','pending_approval','approved','scheduled','active','superseded','expired','terminated')",
      name: "commercial_fee_schedule_versions_status_check"
    add_check_constraint :commercial_fee_schedule_versions,
      "definition_digest ~ '^[0-9a-f]{64}$'",
      name: "commercial_fee_schedule_versions_digest_check"
    add_check_constraint :commercial_fee_schedule_versions,
      "acceptance_policy IN ('none','notice_only','explicit')",
      name: "commercial_fee_schedule_versions_acceptance_policy_check"
    add_check_constraint :commercial_fee_schedule_versions,
      "lock_version >= 0",
      name: "commercial_fee_schedule_versions_lock_version_check"
    add_check_constraint :commercial_fee_schedule_versions,
      "effective_until IS NULL OR effective_from IS NULL OR effective_until > effective_from",
      name: "commercial_fee_schedule_versions_effective_interval_check"
    add_check_constraint :commercial_fee_schedule_versions,
      "status NOT IN ('scheduled','active') OR effective_from IS NOT NULL",
      name: "commercial_fee_schedule_versions_authoritative_start_check"
    add_foreign_key :commercial_fee_schedule_versions, :commercial_fee_schedules,
                    column: :fee_schedule_id, on_delete: :restrict
    add_foreign_key :commercial_fee_schedule_versions, :commercial_fee_schedule_versions,
                    column: :supersedes_version_id, on_delete: :restrict
    add_foreign_key :commercial_fee_schedule_versions, :legal_document_versions,
                    column: :legal_document_version_id, on_delete: :restrict
    %i[submitted_by_id approved_by_id activated_by_id terminated_by_id].each do |column|
      add_foreign_key :commercial_fee_schedule_versions, :core_users,
                      column: column, on_delete: :restrict
    end

    add_exclusion_constraint :commercial_fee_schedule_versions,
      "fee_schedule_id WITH =, tstzrange(effective_from, COALESCE(effective_until, 'infinity'::timestamptz), '[)') WITH &&",
      using: :gist,
      # A scheduled successor may overlap the current active interval until
      # activation closes the old state. Only overlapping active definitions
      # are forbidden at the database boundary.
      where: "status = 'active' AND effective_from IS NOT NULL",
      name: "commercial_fee_schedule_versions_authoritative_interval"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_fee_schedule_version_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            IF OLD.status IN ('approved','scheduled','active','superseded','expired','terminated') THEN
              IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
              END IF;

              IF (OLD.fee_schedule_id, OLD.supersedes_version_id, OLD.version,
                  OLD.definition_digest, OLD.legal_document_version_id,
                  OLD.acceptance_policy, OLD.grandfather_until,
                  OLD.effective_from, OLD.effective_until)
                 IS DISTINCT FROM
                 (NEW.fee_schedule_id, NEW.supersedes_version_id, NEW.version,
                  NEW.definition_digest, NEW.legal_document_version_id,
                  NEW.acceptance_policy, NEW.grandfather_until,
                  NEW.effective_from, NEW.effective_until) THEN
                RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
              END IF;
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_commercial_fee_schedule_version_immutable
            ON commercial_fee_schedule_versions;
          CREATE TRIGGER trg_commercial_fee_schedule_version_immutable
            BEFORE UPDATE OR DELETE ON commercial_fee_schedule_versions
            FOR EACH ROW EXECUTE FUNCTION commercial_fee_schedule_version_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_commercial_fee_schedule_version_immutable ON commercial_fee_schedule_versions;"
        execute "DROP FUNCTION IF EXISTS commercial_fee_schedule_version_immutable();"
      end
    end
  end
end
