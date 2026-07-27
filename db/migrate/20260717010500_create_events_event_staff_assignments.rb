# frozen_string_literal: true

class CreateEventsEventStaffAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_staff_assignments, id: false do |t|
      t.uuid :id, null: false, primary_key: true, default: -> { "uuidv7()" }
      # Business discriminator: manager, staff, scanner, contractor.
      t.string :role, null: false
      t.uuid :event_id, null: false
      t.uuid :user_id, null: false
      t.uuid :organization_id, null: false
      t.string :status, null: false, default: "active"
      t.timestamptz :expires_at
      t.timestamps

      t.index [ :event_id, :user_id, :role ], unique: true
      t.index :user_id
      t.index :organization_id
    end

    add_foreign_key :events_event_staff_assignments, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_staff_assignments, :core_users,
                    column: :user_id, on_delete: :cascade
    add_foreign_key :events_event_staff_assignments, :organizations_organizations,
                    column: :organization_id, on_delete: :cascade

    add_check_constraint :events_event_staff_assignments,
                         "role IN ('manager','staff','scanner','contractor')",
                         name: "chk_event_staff_assignments_role"
    add_check_constraint :events_event_staff_assignments,
                         "status IN ('active','suspended','revoked','expired')",
                         name: "chk_event_staff_assignments_status"
  end
end
