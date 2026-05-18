class CreatePlatformRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_roles, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.string :code, null: false, limit: 50
      t.string :name, null: false, limit: 100
      t.string :description
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :platform_roles, :code, unique: true
    add_index :platform_roles, :active
  end
end
