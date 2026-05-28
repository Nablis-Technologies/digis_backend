class CreateCoreRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :core_roles, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :code, null: false, limit: 50
      t.string :name, null: false, limit: 100
      t.string :description
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :core_roles, :code, unique: true
    add_index :core_roles, :active
  end
end
