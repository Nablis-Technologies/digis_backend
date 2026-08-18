# frozen_string_literal: true

class CreateEventsEventDateChanges < ActiveRecord::Migration[8.1]
  def change
    # Append-only ledger of schedule changes. Snapshot columns are non-nullable
    # so every row is a complete, immutable record of one reschedule.
    create_table :events_event_date_changes, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid        :event_id,       null: false
      t.uuid        :event_date_id,  null: false
      t.uuid        :event_cancellation_id
      t.string      :change_type,    null: false, default: "reschedule"
      t.timestamptz :old_start_at,   null: false
      t.timestamptz :old_end_at,     null: false
      t.timestamptz :new_start_at
      t.timestamptz :new_end_at
      t.uuid        :scheduled_by_id, null: false
      t.timestamps
    end

    add_index :events_event_date_changes, :event_id
    add_index :events_event_date_changes, :event_date_id
    add_index :events_event_date_changes, [ :event_id, :created_at ]
    add_index :events_event_date_changes, %i[event_cancellation_id event_date_id],
              unique: true,
              where: "event_cancellation_id IS NOT NULL",
              name: "idx_event_date_changes_on_cancellation_and_date"

    add_foreign_key :events_event_date_changes, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_date_changes, :events_event_dates,
                    column: :event_date_id, on_delete: :cascade
    add_foreign_key :events_event_date_changes, :core_users,
                    column: :scheduled_by_id, on_delete: :restrict

    add_check_constraint :events_event_date_changes,
      "change_type IN ('reschedule','cancelled')",
      name: "events_event_date_changes_type_check"
    add_check_constraint :events_event_date_changes,
      "(change_type = 'reschedule' AND new_start_at IS NOT NULL AND new_end_at IS NOT NULL) OR " \
      "(change_type = 'cancelled' AND new_start_at IS NULL AND new_end_at IS NULL)",
      name: "events_event_date_changes_new_schedule_shape_check"
  end
end
