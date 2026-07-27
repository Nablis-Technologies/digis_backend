# frozen_string_literal: true

class CreateEventsEventSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_settings, id: false do |t|
      t.uuid :id, null: false, primary_key: true, default: -> { "uuidv7()" }
      t.uuid :event_id, null: false
      t.jsonb :config, null: false, default: {}
      t.timestamps

      t.index :event_id, unique: true
    end

    add_foreign_key :events_event_settings, :events_events,
                    column: :event_id, on_delete: :cascade
  end
end
