class CreateCoreRefreshTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :core_refresh_tokens, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { to_table: :core_users }
      t.string :refresh_token, null: false
      t.datetime :expires_at, null: false
      t.string :device_id
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    add_index :core_refresh_tokens, :refresh_token, unique: true
    add_index :core_refresh_tokens, :expires_at
    add_index :core_refresh_tokens, :device_id
  end
end
