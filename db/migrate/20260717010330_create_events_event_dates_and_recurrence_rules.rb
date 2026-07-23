# frozen_string_literal: true

class CreateEventsEventDatesAndRecurrenceRules < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_dates, id: :uuid do |t|
      t.uuid    :event_id,         null: false
      t.uuid    :venue_id
      t.string  :name
      t.timestamptz :doors_at
      t.timestamptz :starts_at,     null: false
      t.timestamptz :ends_at,       null: false
      t.string  :status,            null: false, default: "scheduled"
      t.integer :venue_capacity
      t.integer :held_venue_count,  null: false, default: 0
      t.integer :issued_venue_count, null: false, default: 0
      t.string  :source_key
      t.timestamps
    end

    add_index :events_event_dates, :event_id
    add_index :events_event_dates, [ :event_id, :starts_at ]
    add_index :events_event_dates, [ :event_id, :source_key ], unique: true,
              where: "source_key IS NOT NULL",
              name: "index_events_event_dates_on_event_id_and_source_key"

    add_check_constraint :events_event_dates, "ends_at > starts_at",
                         name: "chk_event_dates_ends_after_starts"
    add_check_constraint :events_event_dates, "doors_at IS NULL OR doors_at <= starts_at",
                         name: "chk_event_dates_doors_before_starts"
    add_check_constraint :events_event_dates, "held_venue_count >= 0 AND issued_venue_count >= 0",
                         name: "chk_event_dates_counts_nonnegative"

    create_table :events_recurrence_rules, id: :uuid do |t|
      t.uuid    :event_id,            null: false
      t.text    :rrule,               null: false
      t.string  :timezone,            null: false
      t.timestamp :dtstart_local,     null: false
      t.integer :duration_seconds,    null: false
      t.timestamptz :generated_until
      t.boolean :active,            null: false, default: true
      t.jsonb   :exdates,             null: false, default: []
      t.jsonb   :rdates,              null: false, default: []
      t.timestamps
    end

    add_index :events_recurrence_rules, :event_id, unique: true,
              name: "index_events_recurrence_rules_on_event_id"
    add_check_constraint :events_recurrence_rules, "duration_seconds > 0",
                         name: "chk_recurrence_duration_positive"
  end
end
