# frozen_string_literal: true

class CreateTicketingScannerInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_scanner_invitations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :organization_id, null: false
      t.uuid :created_by_id, null: false
      t.text :phone_ciphertext, null: false
      t.string :phone_digest, limit: 64, null: false
      t.string :display_label
      t.text :organizer_note
      t.text :token_ciphertext
      t.string :token_digest, limit: 64, null: false
      t.text :pairing_code_ciphertext
      t.string :pairing_code_digest, limit: 64, null: false
      t.string :status, null: false, default: "pending"
      t.string :delivery_status, null: false, default: "queued"
      t.integer :delivery_revision, null: false, default: 1
      t.integer :delivery_attempts, null: false, default: 0
      t.string :zone_mode, null: false, default: "all_current_zones"
      t.jsonb :selected_zone_ids, null: false, default: []
      t.timestamptz :starts_at, null: false
      t.timestamptz :ends_at, null: false
      t.timestamptz :expires_at, null: false
      t.timestamptz :pairing_code_expires_at, null: false
      t.string :create_idempotency_key_digest, limit: 64, null: false
      t.string :create_request_digest, limit: 64, null: false
      t.uuid :paired_user_id
      t.uuid :event_staff_assignment_id
      t.uuid :scanner_device_id
      t.uuid :scanner_device_assignment_id
      t.string :pairing_method
      t.timestamptz :paired_at
      t.timestamptz :revoked_at
      t.timestamptz :expired_at
      t.timestamptz :last_delivery_at

      t.timestamps
    end

    add_check_constraint :ticketing_scanner_invitations,
      "status IN ('pending','paired','pairing_reset','expired','revoked')",
      name: "ticketing_scanner_invitations_status_check"
    add_check_constraint :ticketing_scanner_invitations,
      "delivery_status IN ('queued','accepted','delivered','failed','unknown')",
      name: "ticketing_scanner_invitations_delivery_status_check"
    add_check_constraint :ticketing_scanner_invitations,
      "zone_mode IN ('all_current_zones','selected_zones') AND jsonb_typeof(selected_zone_ids) = 'array'",
      name: "ticketing_scanner_invitations_zone_scope_check"
    add_check_constraint :ticketing_scanner_invitations,
      "delivery_revision > 0 AND delivery_attempts >= 0",
      name: "ticketing_scanner_invitations_attempts_check"
    add_check_constraint :ticketing_scanner_invitations,
      "starts_at < ends_at AND expires_at <= ends_at AND pairing_code_expires_at <= expires_at",
      name: "ticketing_scanner_invitations_window_check"
    add_check_constraint :ticketing_scanner_invitations,
      "phone_digest ~ '^[0-9a-f]{64}$' AND token_digest ~ '^[0-9a-f]{64}$' AND " \
        "pairing_code_digest ~ '^[0-9a-f]{64}$' AND " \
        "create_idempotency_key_digest ~ '^[0-9a-f]{64}$' AND " \
        "create_request_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_scanner_invitations_digests_check"
    add_check_constraint :ticketing_scanner_invitations,
      "(status = 'paired' AND paired_at IS NOT NULL AND paired_user_id IS NOT NULL AND " \
        "event_staff_assignment_id IS NOT NULL AND scanner_device_id IS NOT NULL AND " \
        "scanner_device_assignment_id IS NOT NULL AND pairing_method IS NOT NULL) OR " \
        "(status <> 'paired' AND paired_at IS NULL)",
      name: "ticketing_scanner_invitations_pairing_state_check"

    add_index :ticketing_scanner_invitations, :token_digest, unique: true
    add_index :ticketing_scanner_invitations, :create_idempotency_key_digest, unique: true
    add_index :ticketing_scanner_invitations, %i[event_id phone_digest],
              unique: true,
              where: "status IN ('pending','paired','pairing_reset')",
              name: "idx_live_ticketing_scanner_invitation_phone"
    add_index :ticketing_scanner_invitations, :pairing_code_digest,
              unique: true,
              where: "status IN ('pending','pairing_reset')",
              name: "idx_live_ticketing_scanner_invitation_code"
    add_index :ticketing_scanner_invitations, %i[event_id status expires_at]
    add_index :ticketing_scanner_invitations, %i[organization_id status]
    add_index :ticketing_scanner_invitations, :created_by_id

    add_foreign_key :ticketing_scanner_invitations, :events_events, column: :event_id
    add_foreign_key :ticketing_scanner_invitations, :organizations_organizations, column: :organization_id
    add_foreign_key :ticketing_scanner_invitations, :core_users, column: :created_by_id
    add_foreign_key :ticketing_scanner_invitations, :core_users, column: :paired_user_id
    add_foreign_key :ticketing_scanner_invitations, :events_event_staff_assignments,
                    column: :event_staff_assignment_id
    add_foreign_key :ticketing_scanner_invitations, :ticketing_scanner_devices,
                    column: :scanner_device_id
    add_foreign_key :ticketing_scanner_invitations, :ticketing_scanner_device_assignments,
                    column: :scanner_device_assignment_id
  end
end
