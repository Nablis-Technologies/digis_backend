# frozen_string_literal: true

class CreateEventsEventVideoLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_video_links, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid    :event_id,      null: false
      t.uuid    :created_by_id, null: false
      t.string  :provider,      null: false, default: "youtube"
      t.string  :url,           null: false
      t.string  :title
      t.text    :caption
      t.integer :position,      null: false, default: 0
      t.timestamps
    end

    add_index :events_event_video_links, %i[event_id position],
              name: "index_event_video_links_on_event_position"
    add_check_constraint :events_event_video_links,
                         "provider IN ('youtube')",
                         name: "chk_event_video_links_provider"
    add_foreign_key :events_event_video_links, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_video_links, :core_users,
                    column: :created_by_id, on_delete: :restrict
  end
end
