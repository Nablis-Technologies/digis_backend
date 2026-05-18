class CreatePlatformUserRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_user_roles, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { to_table: :platform_users }
      t.references :role, null: false, type: :uuid, foreign_key: { to_table: :platform_roles }
      t.references :assigned_by, null: true, type: :uuid, foreign_key: { to_table: :platform_users }
      t.datetime :expires_at

      t.timestamps
    end

    add_index :platform_user_roles, %i[user_id role_id], unique: true
    add_index :platform_user_roles, :expires_at
  end
end
