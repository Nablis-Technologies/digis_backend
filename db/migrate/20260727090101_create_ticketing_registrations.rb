# frozen_string_literal: true

class CreateTicketingRegistrations < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_registrations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :ticket_type_id, null: false
      t.uuid :user_id, null: false
      t.uuid :selected_event_date_id
      t.uuid :access_code_id
      t.uuid :invitation_id
      t.string :source, null: false
      t.uuid :created_by_id, null: false
      t.string :issuance_idempotency_key
      t.string :complimentary_reason
      t.string :identity_digest, null: false, limit: 64
      t.integer :package_quantity, null: false, default: 1
      t.integer :admissions_per_unit_snapshot, null: false, limit: 2
      t.integer :party_size, null: false
      t.string :status, null: false, default: "pending_payment"
      t.timestamptz :submitted_at, null: false
      t.timestamptz :waitlisted_at
      t.timestamptz :offered_at
      t.timestamptz :offer_expires_at
      t.uuid :reviewed_by_id
      t.timestamptz :approved_at
      t.timestamptz :rejected_at
      t.text :decision_reason
      t.timestamptz :confirmed_at
      t.timestamptz :cancelled_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_check_constraint :ticketing_registrations,
      "source IN ('self_service','organizer_complimentary','walk_up')",
      name: "ticketing_registrations_source_check"
    add_check_constraint :ticketing_registrations,
      "status IN ('pending_payment','pending_approval','waitlisted','offered','confirmed','rejected','cancelled','expired')",
      name: "ticketing_registrations_status_check"
    add_check_constraint :ticketing_registrations,
      "package_quantity > 0 AND admissions_per_unit_snapshot > 0 AND party_size > 0",
      name: "ticketing_registrations_quantities_positive_check"
    add_check_constraint :ticketing_registrations,
      "party_size = package_quantity * admissions_per_unit_snapshot",
      name: "ticketing_registrations_party_size_check"
    add_check_constraint :ticketing_registrations,
      "identity_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_registrations_identity_digest_check"
    add_check_constraint :ticketing_registrations,
      "(source = 'organizer_complimentary' AND complimentary_reason IS NOT NULL " \
        "AND complimentary_reason <> '' AND issuance_idempotency_key IS NOT NULL " \
        "AND issuance_idempotency_key <> '') OR " \
        "(source <> 'organizer_complimentary' AND complimentary_reason IS NULL)",
      name: "ticketing_registrations_source_metadata_check"
    add_check_constraint :ticketing_registrations,
      "complimentary_reason IS NULL OR complimentary_reason IN " \
        "('accessibility','accommodation','community_partner','service_recovery','sponsor_guest','staff_guest')",
      name: "ticketing_registrations_complimentary_reason_check"
    add_check_constraint :ticketing_registrations,
      "((status = 'waitlisted' AND waitlisted_at IS NOT NULL) OR " \
        "(status <> 'waitlisted' AND waitlisted_at IS NULL)) AND " \
        "((status = 'offered' AND offered_at IS NOT NULL AND offer_expires_at IS NOT NULL " \
        "AND offer_expires_at > offered_at) OR " \
        "(status <> 'offered' AND offered_at IS NULL AND offer_expires_at IS NULL))",
      name: "ticketing_registrations_state_timestamps_check"
    add_check_constraint :ticketing_registrations,
      "NOT (approved_at IS NOT NULL AND rejected_at IS NOT NULL)",
      name: "ticketing_registrations_decision_exclusive_check"

    add_index :ticketing_registrations, %i[event_id status created_at]
    add_index :ticketing_registrations, %i[ticket_type_id user_id selected_event_date_id]
    add_index :ticketing_registrations, %i[ticket_type_id identity_digest]
    add_index :ticketing_registrations,
      %i[ticket_type_id selected_event_date_id status waitlisted_at id],
      name: "idx_ticketing_registrations_queue"
    add_index :ticketing_registrations,
      "ticket_type_id, identity_digest, COALESCE(selected_event_date_id, '00000000-0000-0000-0000-000000000000'::uuid)",
      unique: true,
      where: "status IN ('pending_payment','pending_approval','waitlisted','offered','confirmed')",
      name: "idx_ticketing_registrations_active_identity"
    add_index :ticketing_registrations, :issuance_idempotency_key,
              unique: true,
              where: "issuance_idempotency_key IS NOT NULL",
              name: "idx_ticketing_registrations_issuance_idempotency"

    add_foreign_key :ticketing_registrations, :events_events, column: :event_id
    add_foreign_key :ticketing_registrations, :ticketing_ticket_types, column: :ticket_type_id
    add_foreign_key :ticketing_registrations, :core_users, column: :user_id
    add_foreign_key :ticketing_registrations, :events_event_dates, column: :selected_event_date_id
    add_foreign_key :ticketing_registrations, :ticketing_access_codes, column: :access_code_id
    add_foreign_key :ticketing_registrations, :ticketing_invitations, column: :invitation_id
    add_foreign_key :ticketing_registrations, :core_users, column: :created_by_id
    add_foreign_key :ticketing_registrations, :core_users, column: :reviewed_by_id
  end
end
