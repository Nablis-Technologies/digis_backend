# frozen_string_literal: true

# Transactional outbox for at-least-once event delivery: rows are written in the
# same transaction as the domain change, then published out-of-band by the
# dispatcher once the handler confirms success.
class CreateCoreOutboxEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :core_outbox_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :topic, null: false
      t.string :event_type, null: false
      t.string :aggregate_type, null: false
      t.uuid :aggregate_id, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :idempotency_key, null: false
      t.datetime :occurred_at, null: false
      t.datetime :available_at, null: false
      t.datetime :published_at
      t.integer :attempts, null: false, default: 0
      t.string :last_error_code
      t.datetime :locked_at
      t.timestamps
    end

    # Idempotency boundary: one row per unique key.
    add_index :core_outbox_events, :idempotency_key, unique: true
    # Dispatcher scan: unpublished rows whose availability window has opened.
    add_index :core_outbox_events, %i[published_at available_at id]
    # Reconstruct an aggregate's event history in occurrence order.
    add_index :core_outbox_events, %i[aggregate_type aggregate_id occurred_at]
    add_index :core_outbox_events, :event_type

    # Keep discriminator fields nonblank and time ordering sane at the database
    # level, since these are the correctness boundaries for delivery.
    add_check_constraint(:core_outbox_events, "topic <> ''", name: "core_outbox_events_topic_nonblank")
    add_check_constraint(:core_outbox_events, "event_type <> ''", name: "core_outbox_events_event_type_nonblank")
    add_check_constraint(:core_outbox_events, "aggregate_type <> ''", name: "core_outbox_events_aggregate_type_nonblank")
    add_check_constraint(:core_outbox_events, "available_at >= occurred_at", name: "core_outbox_events_available_after_occurred")
    add_check_constraint(
      :core_outbox_events,
      "published_at IS NULL OR published_at >= occurred_at",
      name: "core_outbox_events_published_after_occurred"
    )
  end
end
