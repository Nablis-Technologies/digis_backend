class CreateCoreReauthenticationProofs < ActiveRecord::Migration[8.1]
  def change
    create_table :core_reauthentication_proofs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { to_table: :core_users }
      t.string :session_jti_digest, null: false, limit: 64
      t.string :purpose, null: false
      t.string :factor_type, null: false
      t.string :token_digest, null: false, limit: 64
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps null: false
    end

    add_index :core_reauthentication_proofs, :token_digest, unique: true,
      name: "index_core_reauthentication_proofs_on_token_digest"
    add_index :core_reauthentication_proofs, %i[user_id purpose expires_at],
      name: "index_core_reauthentication_proofs_on_user_purpose_expiry"

    add_check_constraint :core_reauthentication_proofs,
      "purpose IN ('attendee_export_request', 'attendee_export_download')",
      name: "core_reauthentication_proofs_purpose_allowlist"
    add_check_constraint :core_reauthentication_proofs,
      "factor_type IN ('password')",
      name: "core_reauthentication_proofs_factor_allowlist"
    add_check_constraint :core_reauthentication_proofs,
      "session_jti_digest ~ '^[0-9a-f]{64}$' AND token_digest ~ '^[0-9a-f]{64}$'",
      name: "core_reauthentication_proofs_digest_shape"
    add_check_constraint :core_reauthentication_proofs,
      "expires_at = issued_at + INTERVAL '5 minutes'",
      name: "core_reauthentication_proofs_exact_lifetime"
    add_check_constraint :core_reauthentication_proofs,
      "expires_at >= issued_at",
      name: "core_reauthentication_proofs_ordered_window"
    add_check_constraint :core_reauthentication_proofs,
      "consumed_at IS NULL OR consumed_at >= issued_at",
      name: "core_reauthentication_proofs_consumed_after_issue"
  end
end
