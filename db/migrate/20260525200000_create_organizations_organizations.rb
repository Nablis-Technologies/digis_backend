class CreateOrganizationsOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations_organizations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description

      t.timestamps
    end

    add_index :organizations_organizations, :slug, unique: true
  end
end
