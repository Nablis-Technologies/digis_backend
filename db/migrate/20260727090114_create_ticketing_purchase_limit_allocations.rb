# frozen_string_literal: true

class CreateTicketingPurchaseLimitAllocations < ActiveRecord::Migration[8.1]
  RELEASE_REASONS = %w[expired checkout_expired cancelled refunded void resale_replaced].freeze

  def change
    create_table :ticketing_purchase_limit_allocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_type_id, null: false
      t.uuid :user_id, null: false
      t.uuid :scope_event_date_id
      t.uuid :registration_id, null: false
      t.integer :unit_number, null: false
      t.uuid :ticket_id
      t.string :status, null: false
      t.timestamptz :expires_at
      t.timestamptz :committed_at
      t.timestamptz :released_at
      t.string :release_reason
      t.string :idempotency_key, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_purchase_limit_allocations,
      "unit_number > 0",
      name: "ticketing_purchase_limit_allocations_unit_check"
    add_check_constraint :ticketing_purchase_limit_allocations,
      "status IN ('reserved','committed','released')",
      name: "ticketing_purchase_limit_allocations_status_check"
    add_check_constraint :ticketing_purchase_limit_allocations,
      "release_reason IS NULL OR release_reason IN (#{RELEASE_REASONS.map { |reason| "'#{reason}'" }.join(',')})",
      name: "ticketing_purchase_limit_allocations_release_reason_check"
    add_check_constraint :ticketing_purchase_limit_allocations,
      "(status = 'reserved' AND expires_at IS NOT NULL AND committed_at IS NULL " \
        "AND released_at IS NULL AND release_reason IS NULL) OR " \
        "(status = 'committed' AND expires_at IS NULL AND committed_at IS NOT NULL " \
        "AND released_at IS NULL AND release_reason IS NULL) OR " \
        "(status = 'released' AND expires_at IS NULL AND committed_at IS NULL " \
        "AND released_at IS NOT NULL AND release_reason IS NOT NULL AND release_reason <> '')",
      name: "ticketing_purchase_limit_allocations_state_check"

    add_index :ticketing_purchase_limit_allocations,
      %i[ticket_type_id scope_event_date_id user_id status expires_at],
      name: "idx_ticketing_purchase_limit_allocations_count"
    add_index :ticketing_purchase_limit_allocations,
      %i[registration_id unit_number],
      unique: true,
      name: "idx_ticketing_purchase_limit_allocations_registration_unit"
    add_index :ticketing_purchase_limit_allocations,
      %i[registration_id ticket_id],
      unique: true,
      where: "ticket_id IS NOT NULL",
      name: "idx_ticketing_purchase_limit_allocations_registration_ticket"
    add_index :ticketing_purchase_limit_allocations,
      :idempotency_key,
      unique: true,
      name: "idx_ticketing_purchase_limit_allocations_idempotency"

    add_foreign_key :ticketing_purchase_limit_allocations,
      :ticketing_ticket_types,
      column: :ticket_type_id
    add_foreign_key :ticketing_purchase_limit_allocations,
      :core_users,
      column: :user_id
    add_foreign_key :ticketing_purchase_limit_allocations,
      :events_event_dates,
      column: :scope_event_date_id
    add_foreign_key :ticketing_purchase_limit_allocations,
      :ticketing_registrations,
      column: :registration_id
  end
end
