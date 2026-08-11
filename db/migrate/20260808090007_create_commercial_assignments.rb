class CreateCommercialAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_assignments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :event_id
      t.uuid :fee_schedule_version_id, null: false
      t.uuid :program_id
      t.string :assignment_type, null: false
      t.string :status, null: false, default: "draft"
      t.text :reason, null: false
      t.string :external_reference
      t.uuid :legal_acceptance_id
      t.timestamptz :effective_from, null: false
      t.timestamptz :effective_until
      t.string :risk_level, null: false
      t.uuid :created_by_id, null: false
      t.uuid :approved_by_id
      t.timestamptz :approved_at
      t.uuid :activated_by_id
      t.timestamptz :activated_at
      t.uuid :terminated_by_id
      t.timestamptz :terminated_at
      t.uuid :external_accepted_by_id
      t.timestamptz :external_accepted_at
      t.string :baseline_resolution_digest, limit: 64
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :commercial_assignments, %i[organization_id status effective_from],
              name: "idx_commercial_assignments_on_org_status_start"
    add_index :commercial_assignments, %i[organization_id event_id status effective_from],
              include: %i[fee_schedule_version_id program_id effective_until],
              where: "status IN ('scheduled','active')",
              name: "idx_commercial_assignments_active_resolution"
    add_index :commercial_assignments, %i[event_id status effective_from],
              where: "event_id IS NOT NULL",
              name: "idx_commercial_assignments_on_event_status_start"
    add_index :commercial_assignments, :fee_schedule_version_id
    add_index :commercial_assignments, :program_id
    add_index :commercial_assignments, :legal_acceptance_id
    add_index :commercial_assignments, :created_by_id

    add_check_constraint :commercial_assignments,
      "assignment_type IN ('program','platform_grant','mutual_agreement')",
      name: "commercial_assignments_assignment_type_check"
    add_check_constraint :commercial_assignments,
      "status IN ('draft','pending_acceptance','pending_approval','scheduled','active','expired','terminated')",
      name: "commercial_assignments_status_check"
    add_check_constraint :commercial_assignments,
      "risk_level IN ('low','medium','high')",
      name: "commercial_assignments_risk_level_check"
    add_check_constraint :commercial_assignments,
      "effective_until IS NULL OR effective_until > effective_from",
      name: "commercial_assignments_effective_interval_check"
    add_check_constraint :commercial_assignments,
      "lock_version >= 0",
      name: "commercial_assignments_lock_version_check"
    add_check_constraint :commercial_assignments,
      "baseline_resolution_digest IS NULL OR baseline_resolution_digest ~ '^[0-9a-f]{64}$'",
      name: "commercial_assignments_baseline_digest_check"
    add_check_constraint :commercial_assignments,
      "assignment_type <> 'platform_grant' OR baseline_resolution_digest IS NOT NULL",
      name: "commercial_assignments_platform_grant_baseline_check"
    add_check_constraint :commercial_assignments,
      "external_reference IS NULL OR NULLIF(BTRIM(external_reference), '') IS NOT NULL",
      name: "commercial_assignments_external_reference_check"
    add_check_constraint :commercial_assignments,
      "external_reference IS NULL OR (external_accepted_by_id IS NOT NULL AND external_accepted_at IS NOT NULL)",
      name: "commercial_assignments_external_acceptance_metadata_check"
    add_check_constraint :commercial_assignments,
      "assignment_type <> 'mutual_agreement' OR status NOT IN ('scheduled','active') OR legal_acceptance_id IS NOT NULL OR NULLIF(BTRIM(external_reference), '') IS NOT NULL",
      name: "commercial_assignments_mutual_evidence_check"
    add_check_constraint :commercial_assignments,
      "status <> 'active' OR (activated_by_id IS NOT NULL AND activated_at IS NOT NULL)",
      name: "commercial_assignments_active_metadata_check"
    add_check_constraint :commercial_assignments,
      "status <> 'terminated' OR (terminated_by_id IS NOT NULL AND terminated_at IS NOT NULL)",
      name: "commercial_assignments_terminated_metadata_check"

    add_foreign_key :commercial_assignments, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :commercial_assignments, :events_events,
                    column: :event_id, on_delete: :restrict
    add_foreign_key :commercial_assignments, :commercial_fee_schedule_versions,
                    column: :fee_schedule_version_id, on_delete: :restrict
    add_foreign_key :commercial_assignments, :commercial_programs,
                    column: :program_id, on_delete: :restrict
    add_foreign_key :commercial_assignments, :legal_acceptances,
                    column: :legal_acceptance_id, on_delete: :restrict
    %i[created_by_id approved_by_id activated_by_id terminated_by_id external_accepted_by_id].each do |column|
      add_foreign_key :commercial_assignments, :core_users,
                      column: column, on_delete: :restrict
    end
  end
end
