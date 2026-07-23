# frozen_string_literal: true

class CreateEventsEventMedia < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_media, id: :uuid do |t|
      t.uuid    :event_id,      null: false
      t.uuid    :created_by_id, null: false
      t.string  :type,          null: false
      t.integer :position,      null: false, default: 0
      t.string  :alt_text
      t.text    :caption
      t.timestamps
    end

    add_index :events_event_media, %i[event_id type position],
              unique: true,
              name: "index_event_media_on_event_type_position"
    add_index :events_event_media, :created_by_id,
              name: "index_event_media_on_created_by"

    add_check_constraint :events_event_media,
                         "type IN ('cover', 'gallery')",
                         name: "chk_event_media_type"
    add_check_constraint :events_event_media,
                         "position >= 0",
                         name: "chk_event_media_position"
    add_check_constraint :events_event_media,
                         "type <> 'cover' OR position = 0",
                         name: "chk_event_media_cover_position"

    add_foreign_key :events_event_media, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_media, :core_users,
                    column: :created_by_id, on_delete: :restrict
  end
end
