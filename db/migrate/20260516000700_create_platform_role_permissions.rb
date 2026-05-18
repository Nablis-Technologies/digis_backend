class CreatePlatformRolePermissions < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_role_permissions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :role, null: false, type: :uuid, foreign_key: { to_table: :platform_roles }
      t.references :permission, null: false, type: :uuid, foreign_key: { to_table: :platform_permissions }

      t.timestamps
    end

    add_index :platform_role_permissions, %i[role_id permission_id], unique: true
  end
end
