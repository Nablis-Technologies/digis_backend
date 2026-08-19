# frozen_string_literal: true

class CreateLinksShortLinkClicks < ActiveRecord::Migration[8.1]
  def change
    create_table :links_short_link_clicks, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :short_link_id, null: false
      t.text :referrer
      t.string :device_type
      t.string :country, limit: 2
      t.timestamptz :clicked_at, null: false

      t.timestamps
    end

    add_index :links_short_link_clicks, %i[short_link_id clicked_at], order: { clicked_at: :desc }
    add_foreign_key :links_short_link_clicks, :links_short_links,
                    column: :short_link_id, on_delete: :restrict
  end
end
