class CreatePlatformUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_users, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.string :email, limit: 150
      t.string :phone, limit: 30
      t.datetime :verified_at
      t.boolean :temp_password, null: false, default: false
      t.string :password_digest, null: false

      t.timestamps
    end

    add_index :platform_users, :email, unique: true
    add_index :platform_users, :phone, unique: true
  end
end
