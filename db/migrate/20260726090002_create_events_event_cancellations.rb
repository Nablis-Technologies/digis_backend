# frozen_string_literal: true

class CreateEventsEventCancellations < ActiveRecord::Migration[8.1]
  def change
    # At most one cancellation per event: cancellation is an irreversible
    # boundary, so the unique event_id makes a second attempt impossible.
    create_table :events_event_cancellations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid        :event_id,        null: false
      t.uuid        :initiated_by_id, null: false
      t.string      :status,          null: false, default: "pending"
      t.string      :idempotency_key, null: false
      t.text        :attendee_reason, null: false
      t.text        :internal_note
      t.integer     :total_payments_count,    null: false, default: 0
      t.integer     :resolved_payments_count, null: false, default: 0
      t.integer     :failed_payments_count,   null: false, default: 0
      t.timestamptz :initiated_at,       null: false
      t.timestamptz :refunds_started_at
      t.timestamptz :completed_at
      t.text        :last_error
      t.integer     :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :events_event_cancellations, :event_id, unique: true
    add_index :events_event_cancellations, :idempotency_key, unique: true
    add_index :events_event_cancellations, :initiated_by_id
    add_index :events_event_cancellations, %i[status updated_at]

    add_foreign_key :events_event_cancellations, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_cancellations, :core_users,
                    column: :initiated_by_id, on_delete: :restrict
    add_foreign_key :events_event_date_changes, :events_event_cancellations,
                    column: :event_cancellation_id, on_delete: :restrict

    add_check_constraint :events_event_cancellations,
                         "status IN ('pending','processing','completed','partially_failed')",
                         name: "chk_events_event_cancellations_status"
    add_check_constraint :events_event_cancellations,
                         "total_payments_count >= 0 AND resolved_payments_count >= 0 AND " \
                         "failed_payments_count >= 0 AND lock_version >= 0",
                         name: "chk_events_event_cancellations_counters_nonnegative"
    add_check_constraint :events_event_cancellations,
                         "resolved_payments_count + failed_payments_count <= total_payments_count",
                         name: "chk_events_event_cancellations_counters_within_total"
    add_check_constraint :events_event_cancellations,
                         "status <> 'completed' OR " \
                         "resolved_payments_count + failed_payments_count = total_payments_count",
                         name: "chk_events_event_cancellations_completed_counters"
    add_check_constraint :events_event_cancellations,
                         "status <> 'partially_failed' OR failed_payments_count > 0",
                         name: "chk_events_event_cancellations_partial_failure"
  end
end
