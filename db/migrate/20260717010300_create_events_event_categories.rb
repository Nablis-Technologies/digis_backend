# frozen_string_literal: true

class CreateEventsEventCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_categories, id: false do |t|
      t.uuid :id, null: false, primary_key: true, default: -> { "gen_random_uuid()" }
      t.uuid :event_id, null: false
      t.uuid :category_id, null: false
      t.timestamps

      t.index [ :event_id, :category_id ], unique: true
      t.index :category_id
    end

    add_foreign_key :events_event_categories, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_categories, :events_categories,
                    column: :category_id, on_delete: :restrict

    add_check_constraint :events_event_categories,
                         "event_id IS NOT NULL AND category_id IS NOT NULL",
                         name: "chk_event_categories_present"
  end
end
