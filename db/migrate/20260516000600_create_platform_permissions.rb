class CreatePlatformPermissions < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_permissions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.string :code, null: false, limit: 100
      t.string :resource, null: false, limit: 50
      t.string :action, null: false, limit: 50
      t.string :namespace, null: false, default: "platform", limit: 50
      t.string :description
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :platform_permissions, :code, unique: true
    add_index :platform_permissions, :resource
    add_index :platform_permissions, :namespace
    add_index :platform_permissions, :active
    add_index :platform_permissions, %i[resource action namespace], unique: true, name: "index_platform_permissions_on_resource_action_namespace"
  end
end
