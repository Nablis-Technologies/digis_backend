# frozen_string_literal: true

class CreateEventsParticipantsStreamsAccessZones < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_participants, id: :uuid do |t|
      t.uuid    :event_id,         null: false
      t.uuid    :event_date_id
      t.uuid    :artist_id
      t.string  :name,             null: false
      t.string  :type,             null: false
      t.text    :description
      t.integer :display_order,    null: false, default: 0
      t.jsonb   :metadata,         default: {}
      t.timestamps
    end

    add_index :events_event_participants, %i[event_id event_date_id display_order],
              name: "index_event_participants_on_event_date_order"
    add_index :events_event_participants, %i[artist_id event_id],
              name: "index_event_participants_on_artist_event",
              where: "artist_id IS NOT NULL"
    add_check_constraint :events_event_participants,
                         "type IN ('performer','speaker','host','instructor','panelist','team','guest')",
                         name: "chk_event_participants_type"
    add_foreign_key :events_event_participants, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_participants, :events_event_dates,
                    column: :event_date_id, on_delete: :cascade

    create_table :events_event_streams, id: :uuid do |t|
      t.uuid    :event_date_id,             null: false
      t.string  :provider,                 null: false
      t.string  :provider_stream_id
      t.string  :provider_playback_id
      t.string  :access_protection,        null: false
      t.string  :status,                   null: false, default: "scheduled"
      t.timestamptz :live_from,            null: false
      t.timestamptz :live_until,           null: false
      t.boolean :replay_enabled,           null: false, default: false
      t.timestamptz :replay_available_until
      t.integer :max_concurrent_devices,   null: false, default: 1
      t.jsonb   :config,                   default: {}
      t.timestamps
    end

    add_index :events_event_streams, :event_date_id, unique: true,
              name: "index_event_streams_on_event_date"
    add_check_constraint :events_event_streams,
                         "access_protection IN ('public','soft_gated','signed')",
                         name: "chk_event_streams_access_protection"
    add_check_constraint :events_event_streams,
                         "status IN ('scheduled','live','ended','disabled')",
                         name: "chk_event_streams_status"
    add_check_constraint :events_event_streams,
                         "replay_available_until IS NOT NULL OR replay_enabled = false",
                         name: "chk_event_streams_replay_until"
    add_foreign_key :events_event_streams, :events_event_dates,
                    column: :event_date_id, on_delete: :cascade

    create_table :events_access_zones, id: :uuid do |t|
      t.uuid    :event_id,         null: false
      t.uuid    :event_date_id
      t.string  :type,             null: false
      t.string  :name,             null: false
      t.string  :code,             null: false
      t.boolean :active,           null: false, default: true
      t.integer :sort_order,       null: false, default: 0
      t.timestamps
    end

    add_index :events_access_zones, %i[event_id type active sort_order],
              name: "index_access_zones_on_event_type_active_order"
    add_index :events_access_zones, %i[event_id code], unique: true,
              name: "index_access_zones_on_event_code"
    add_check_constraint :events_access_zones,
                         "type IN ('venue','parking')",
                         name: "chk_access_zones_type"
    add_foreign_key :events_access_zones, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_access_zones, :events_event_dates,
                    column: :event_date_id, on_delete: :nullify
  end
end
