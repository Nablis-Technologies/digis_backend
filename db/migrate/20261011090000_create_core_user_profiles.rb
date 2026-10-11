# frozen_string_literal: true

class CreateCoreUserProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :core_user_profiles, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :user_id, null: false
      t.string :first_name, limit: 100, null: false
      t.string :last_name, limit: 100, null: false
      t.timestamps
    end

    add_foreign_key :core_user_profiles, :core_users, column: :user_id
    add_index :core_user_profiles, :user_id, unique: true
  end
end
