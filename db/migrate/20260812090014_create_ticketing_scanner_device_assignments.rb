# frozen_string_literal: true

class CreateTicketingScannerDeviceAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_scanner_device_assignments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :scanner_device_id, null: false
      t.uuid :event_id, null: false
      t.uuid :event_staff_assignment_id, null: false
      t.uuid :assigned_by_id, null: false
      t.string :status, null: false, default: "active"
      t.timestamptz :starts_at
      t.timestamptz :ends_at
      t.bigint :last_revocation_version, null: false, default: 0
      t.bigint :last_attendee_index_version, null: false, default: 0
      t.bigint :last_schedule_version, null: false, default: 0
      t.bigint :last_admission_use_reversal_version, null: false, default: 0
      t.timestamptz :last_synced_at

      t.timestamps
    end

    add_check_constraint :ticketing_scanner_device_assignments,
      "status IN ('active','suspended','revoked','expired')",
      name: "ticketing_scanner_device_assignments_status_check"
    add_check_constraint :ticketing_scanner_device_assignments,
      "last_revocation_version >= 0 AND last_attendee_index_version >= 0 AND " \
        "last_schedule_version >= 0 AND last_admission_use_reversal_version >= 0",
      name: "ticketing_scanner_device_assignments_versions_check"
    add_check_constraint :ticketing_scanner_device_assignments,
      "ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at",
      name: "ticketing_scanner_device_assignments_window_check"

    add_index :ticketing_scanner_device_assignments, %i[scanner_device_id event_id],
              unique: true,
              where: "status = 'active'",
              name: "idx_active_scanner_assignment"
    add_index :ticketing_scanner_device_assignments, %i[event_id status]

    add_foreign_key :ticketing_scanner_device_assignments,
                    :ticketing_scanner_devices,
                    column: :scanner_device_id
    add_foreign_key :ticketing_scanner_device_assignments, :events_events,
                    column: :event_id
    add_foreign_key :ticketing_scanner_device_assignments, :events_event_staff_assignments,
                    column: :event_staff_assignment_id
    add_foreign_key :ticketing_scanner_device_assignments, :core_users,
                    column: :assigned_by_id
  end
end
