class CreateCorePermissions < ActiveRecord::Migration[8.1]
  def change
    create_table :core_permissions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :code, null: false, limit: 100
      t.string :resource, null: false, limit: 50
      t.string :action, null: false, limit: 50
      t.string :namespace, null: false, default: "core", limit: 50
      t.string :description
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :core_permissions, :code, unique: true
    add_index :core_permissions, :resource
    add_index :core_permissions, :namespace
    add_index :core_permissions, :active
    add_index :core_permissions, %i[resource action namespace], unique: true, name: "index_core_permissions_on_resource_action_namespace"
  end
end
