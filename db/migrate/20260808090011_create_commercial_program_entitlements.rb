class CreateCommercialProgramEntitlements < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_program_entitlements, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :program_id, null: false
      t.uuid :organization_id, null: false
      t.string :status, null: false, default: "available"
      t.uuid :reserved_event_id
      t.timestamptz :reserved_at
      t.timestamptz :consumed_at
      t.timestamptz :released_at
      t.timestamptz :expires_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :commercial_program_entitlements, %i[program_id organization_id], unique: true,
              name: "idx_commercial_entitlements_unique_program_organization"
    add_index :commercial_program_entitlements, %i[program_id status]
    add_index :commercial_program_entitlements, %i[organization_id status]
    add_index :commercial_program_entitlements, :reserved_event_id

    add_check_constraint :commercial_program_entitlements,
      "status IN ('available','reserved','consumed','released','expired')",
      name: "commercial_program_entitlements_status_check"
    add_check_constraint :commercial_program_entitlements,
      "lock_version >= 0",
      name: "commercial_program_entitlements_lock_version_check"
    add_check_constraint :commercial_program_entitlements,
      <<~SQL.squish,
        (status = 'available' AND reserved_event_id IS NULL AND reserved_at IS NULL
          AND consumed_at IS NULL AND released_at IS NULL)
        OR (status = 'reserved' AND reserved_event_id IS NOT NULL AND reserved_at IS NOT NULL
          AND consumed_at IS NULL AND released_at IS NULL)
        OR (status = 'consumed' AND reserved_event_id IS NULL AND reserved_at IS NULL
          AND consumed_at IS NOT NULL AND released_at IS NULL)
        OR (status = 'released' AND reserved_event_id IS NULL AND reserved_at IS NULL
          AND consumed_at IS NULL AND released_at IS NOT NULL)
        OR (status = 'expired' AND reserved_event_id IS NULL AND reserved_at IS NULL
          AND consumed_at IS NULL AND released_at IS NULL AND expires_at IS NOT NULL)
      SQL
      name: "commercial_program_entitlements_state_check"

    add_foreign_key :commercial_program_entitlements, :commercial_programs,
                    column: :program_id, on_delete: :restrict
    add_foreign_key :commercial_program_entitlements, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :commercial_program_entitlements, :events_events,
                    column: :reserved_event_id, on_delete: :restrict
  end
end
