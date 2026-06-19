class CreateOrganizationsOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations_organizations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.jsonb :social_links, default: {}
      t.integer :followers_count, default: 0, null: false

      t.string :organizer_type, null: false
      t.string :category, null: false

      t.string :contact_phone
      t.string :contact_email
      t.string :website_url
      t.string :tin_number
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :region

      t.string :estimated_audience
      t.string :event_frequency
      t.text :experience_summary

      t.integer :events_count, default: 0, null: false

      t.timestamps
    end

    add_index :organizations_organizations, :slug, unique: true
  end
end
