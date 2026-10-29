# frozen_string_literal: true

class CreateCorePhoneVerificationChallenges < ActiveRecord::Migration[8.1]
  def change
    create_table :core_phone_verification_challenges, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :user_id, null: false
      t.string :purpose, null: false
      t.string :phone_digest, limit: 64, null: false
      t.string :code_digest, limit: 64, null: false
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 5
      t.timestamptz :expires_at, null: false
      t.timestamptz :verified_at
      t.timestamps
    end

    add_check_constraint :core_phone_verification_challenges,
      "status IN ('pending','verified','expired','exhausted','delivery_failed')",
      name: "core_phone_verification_challenges_status_check"
    add_check_constraint :core_phone_verification_challenges,
      "attempts >= 0 AND max_attempts > 0 AND attempts <= max_attempts",
      name: "core_phone_verification_challenges_attempts_check"
    add_check_constraint :core_phone_verification_challenges,
      "phone_digest ~ '^[0-9a-f]{64}$' AND code_digest ~ '^[0-9a-f]{64}$' AND " \
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "core_phone_verification_challenges_digests_check"
    add_check_constraint :core_phone_verification_challenges,
      "(status = 'verified' AND verified_at IS NOT NULL) OR " \
      "(status <> 'verified' AND verified_at IS NULL)",
      name: "core_phone_verification_challenges_verification_state_check"

    add_index :core_phone_verification_challenges,
      %i[user_id purpose idempotency_key_digest],
      unique: true,
      name: "idx_core_phone_verification_challenges_idempotency"
    add_index :core_phone_verification_challenges, %i[status expires_at]
    add_foreign_key :core_phone_verification_challenges, :core_users, column: :user_id
  end
end
