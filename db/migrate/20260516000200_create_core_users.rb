class CreateCoreUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :core_users, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :email, limit: 150
      t.string :phone, limit: 30
      t.datetime :verified_at
      t.string :password_digest

      t.timestamps
    end

    add_index :core_users, :email, unique: true
    add_index :core_users, :phone, unique: true
  end
end
