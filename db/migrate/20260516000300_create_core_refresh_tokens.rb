class CreateCoreRefreshTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :core_refresh_tokens, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { to_table: :core_users }
      t.string :token_fingerprint, null: false
      t.string :jti, null: false
      t.datetime :expires_at, null: false
      t.boolean :revoked, default: false, null: false
      t.datetime :revoked_at
      t.string :device_id
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    add_index :core_refresh_tokens, :token_fingerprint, unique: true
    add_index :core_refresh_tokens, :jti, unique: true
    add_index :core_refresh_tokens, :expires_at
    add_index :core_refresh_tokens, :device_id
    add_index :core_refresh_tokens, :revoked
  end
end
