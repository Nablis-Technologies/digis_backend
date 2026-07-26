# frozen_string_literal: true

class CreateEventsEventDateChanges < ActiveRecord::Migration[8.1]
  def change
    # Append-only ledger of schedule changes. Snapshot columns are non-nullable
    # so every row is a complete, immutable record of one reschedule.
    create_table :events_event_date_changes, id: :uuid do |t|
      t.uuid        :event_id,       null: false
      t.uuid        :event_date_id,  null: false
      t.string      :change_type,    null: false, default: "reschedule"
      t.timestamptz :old_start_at,   null: false
      t.timestamptz :old_end_at,     null: false
      t.timestamptz :new_start_at,   null: false
      t.timestamptz :new_end_at,     null: false
      t.uuid        :scheduled_by_id, null: false
      t.timestamps
    end

    add_index :events_event_date_changes, :event_id
    add_index :events_event_date_changes, :event_date_id
    add_index :events_event_date_changes, [ :event_id, :created_at ]

    add_foreign_key :events_event_date_changes, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_date_changes, :events_event_dates,
                    column: :event_date_id, on_delete: :cascade
    add_foreign_key :events_event_date_changes, :core_users,
                    column: :scheduled_by_id, on_delete: :restrict
  end
end
