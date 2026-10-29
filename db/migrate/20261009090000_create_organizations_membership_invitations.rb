# frozen_string_literal: true

class CreateOrganizationsMembershipInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations_membership_invitations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :invited_by_id, null: false
      t.uuid :accepted_user_id
      t.string :role, null: false
      t.string :contact_type, null: false
      t.text :contact_ciphertext, null: false
      t.string :contact_digest, limit: 64, null: false
      t.string :status, null: false, default: "pending"
      t.text :claim_token_ciphertext
      t.string :claim_token_digest, limit: 64, null: false
      t.string :delivery_status, null: false, default: "queued"
      t.integer :delivery_revision, null: false, default: 1
      t.integer :delivery_attempts, null: false, default: 0
      t.timestamptz :last_delivery_at
      t.timestamptz :expires_at, null: false
      t.timestamptz :accepted_at
      t.timestamptz :revoked_at
      t.timestamptz :expired_at
      t.string :create_idempotency_key_digest, limit: 64, null: false
      t.string :create_request_digest, limit: 64, null: false
      t.string :claim_idempotency_key_digest, limit: 64
      t.string :claim_request_digest, limit: 64

      t.timestamps
    end

    add_foreign_key :organizations_membership_invitations, :organizations_organizations,
                    column: :organization_id
    add_foreign_key :organizations_membership_invitations, :core_users,
                    column: :invited_by_id
    add_foreign_key :organizations_membership_invitations, :core_users,
                    column: :accepted_user_id

    add_check_constraint :organizations_membership_invitations,
                         "role IN ('admin','staff')",
                         name: "org_membership_invitations_role_check"
    add_check_constraint :organizations_membership_invitations,
                         "contact_type IN ('phone','email')",
                         name: "org_membership_invitations_contact_type_check"
    add_check_constraint :organizations_membership_invitations,
                         "status IN ('pending','accepted','revoked','expired')",
                         name: "org_membership_invitations_status_check"
    add_check_constraint :organizations_membership_invitations,
                         "delivery_status IN ('queued','accepted','delivered','failed','unknown')",
                         name: "org_membership_invitations_delivery_status_check"
    add_check_constraint :organizations_membership_invitations,
                         "delivery_revision > 0 AND delivery_attempts >= 0 AND expires_at > created_at",
                         name: "org_membership_invitations_lifecycle_check"
    add_check_constraint :organizations_membership_invitations,
                         "contact_digest ~ '^[0-9a-f]{64}$' AND claim_token_digest ~ '^[0-9a-f]{64}$' AND " \
                           "create_idempotency_key_digest ~ '^[0-9a-f]{64}$' AND " \
                           "create_request_digest ~ '^[0-9a-f]{64}$' AND " \
                           "(claim_idempotency_key_digest IS NULL OR claim_idempotency_key_digest ~ '^[0-9a-f]{64}$') AND " \
                           "(claim_request_digest IS NULL OR claim_request_digest ~ '^[0-9a-f]{64}$')",
                         name: "org_membership_invitations_digest_check"
    add_check_constraint :organizations_membership_invitations,
                         "(status = 'pending' AND claim_token_ciphertext IS NOT NULL AND accepted_user_id IS NULL AND " \
                           "accepted_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL AND " \
                           "claim_idempotency_key_digest IS NULL AND claim_request_digest IS NULL) OR " \
                           "(status = 'accepted' AND claim_token_ciphertext IS NULL AND accepted_user_id IS NOT NULL AND " \
                           "accepted_at IS NOT NULL AND revoked_at IS NULL AND expired_at IS NULL AND " \
                           "claim_idempotency_key_digest IS NOT NULL AND claim_request_digest IS NOT NULL) OR " \
                           "(status = 'revoked' AND claim_token_ciphertext IS NULL AND accepted_user_id IS NULL AND " \
                           "accepted_at IS NULL AND revoked_at IS NOT NULL AND expired_at IS NULL) OR " \
                           "(status = 'expired' AND claim_token_ciphertext IS NULL AND accepted_user_id IS NULL AND " \
                           "accepted_at IS NULL AND revoked_at IS NULL AND expired_at IS NOT NULL)",
                         name: "org_membership_invitations_state_check"

    add_index :organizations_membership_invitations,
              [ :organization_id, :contact_digest ],
              unique: true,
              where: "status = 'pending'",
              name: "idx_org_membership_invitations_pending_contact"
    add_index :organizations_membership_invitations, :claim_token_digest, unique: true
    add_index :organizations_membership_invitations,
              [ :organization_id, :invited_by_id, :create_idempotency_key_digest ],
              unique: true,
              name: "idx_org_membership_invitations_create_key"
    add_index :organizations_membership_invitations, [ :organization_id, :status, :created_at ]
    add_index :organizations_membership_invitations, :accepted_user_id
    add_index :organizations_membership_invitations, :expires_at, where: "status = 'pending'"
  end
end
