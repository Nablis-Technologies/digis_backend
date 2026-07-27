# frozen_string_literal: true

class CreateEventsEventCancellations < ActiveRecord::Migration[8.1]
  def change
    # At most one cancellation per event: cancellation is an irreversible
    # boundary, so the unique event_id makes a second attempt impossible.
    create_table :events_event_cancellations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid        :event_id,        null: false
      t.uuid        :initiated_by_id, null: false
      t.text        :reason
      t.text        :attendee_reason
      t.string      :status,          null: false, default: "initiated"
      t.string      :idempotency_key, null: false
      t.timestamptz :cancelled_at
      t.timestamps
    end

    add_index :events_event_cancellations, :event_id, unique: true
    add_index :events_event_cancellations, :idempotency_key, unique: true
    add_index :events_event_cancellations, :initiated_by_id

    add_foreign_key :events_event_cancellations, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_cancellations, :core_users,
                    column: :initiated_by_id, on_delete: :restrict

    add_check_constraint :events_event_cancellations,
                         "status IN ('initiated','completed')",
                         name: "chk_events_event_cancellations_status"
    add_check_constraint :events_event_cancellations,
                         "cancelled_at IS NOT NULL",
                         name: "chk_events_event_cancellations_cancelled_at"
  end
end
