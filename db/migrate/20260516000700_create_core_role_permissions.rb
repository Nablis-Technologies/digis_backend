class CreateCoreRolePermissions < ActiveRecord::Migration[8.1]
  def change
    create_table :core_role_permissions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :role, null: false, type: :uuid, foreign_key: { to_table: :core_roles }
      t.references :permission, null: false, type: :uuid, foreign_key: { to_table: :core_permissions }

      t.timestamps
    end

    add_index :core_role_permissions, %i[role_id permission_id], unique: true
  end
end
