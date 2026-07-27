class CreateEventsArtists < ActiveRecord::Migration[8.1]
  def change
    create_table :events_artists, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string   :name,           null: false
      t.string   :slug,           null: false
      t.text     :description
      t.string   :image_url
      t.jsonb    :genres,         default: []
      t.jsonb    :social_links,   default: {}
      t.boolean  :verified,       default: false
      t.boolean  :active,         default: true
      t.integer  :followers_count, default: 0, null: false
      t.jsonb    :metadata,       default: {}
      t.timestamps
    end

    add_index :events_artists, :slug, unique: true
    add_index :events_artists, :verified
    add_index :events_artists, :active
    add_index :events_artists, :genres, using: :gin
  end
end
