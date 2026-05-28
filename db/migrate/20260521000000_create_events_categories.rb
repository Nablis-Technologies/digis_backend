class CreateEventsCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :events_categories, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :description
      t.jsonb :metadata, default: {}, null: false
      t.string :slug, null: false
      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :events_categories, :slug, unique: true
    add_index :events_categories, :active
    add_index :events_categories, :name
  end
end
