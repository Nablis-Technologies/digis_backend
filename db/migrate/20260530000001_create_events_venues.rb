class CreateEventsVenues < ActiveRecord::Migration[8.1]
  def change
    create_table :events_venues, id: :uuid do |t|
      t.string   :name,           null: false
      t.string   :slug,           null: false
      t.text     :description
      t.string   :address
      t.string   :city
      t.string   :country
      t.decimal  :latitude,       precision: 10, scale: 6
      t.decimal  :longitude,      precision: 10, scale: 6
      t.integer  :capacity
      t.jsonb    :amenities,      default: []
      t.jsonb    :social_links,   default: {}
      t.string   :contact_phone
      t.string   :contact_email
      t.string   :website_url
      t.boolean  :verified,       default: false
      t.boolean  :active,         default: true
      t.integer  :followers_count, default: 0, null: false
      t.jsonb    :metadata,       default: {}
      t.timestamps
    end

    add_index :events_venues, :slug, unique: true
    add_index :events_venues, :city
    add_index :events_venues, :country
    add_index :events_venues, :verified
    add_index :events_venues, :active
  end
end
