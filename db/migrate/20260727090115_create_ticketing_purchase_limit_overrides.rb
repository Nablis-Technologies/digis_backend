# frozen_string_literal: true

class CreateTicketingPurchaseLimitOverrides < ActiveRecord::Migration[8.1]
  REASON_CODES = %w[
    accessibility accommodation community_partner service_recovery sponsor_guest staff_guest
    organizer_exception
  ].freeze

  def change
    create_table :ticketing_purchase_limit_overrides, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_id, null: false
      t.uuid :ticket_type_id, null: false
      t.uuid :user_id, null: false
      t.uuid :scope_event_date_id
      t.integer :additional_packages, null: false
      t.uuid :approved_by_id, null: false
      t.string :reason_code, null: false
      t.string :idempotency_key, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_purchase_limit_overrides,
      "additional_packages > 0",
      name: "ticketing_purchase_limit_overrides_packages_check"
    add_check_constraint :ticketing_purchase_limit_overrides,
      "reason_code IN (#{REASON_CODES.map { |code| "'#{code}'" }.join(',')})",
      name: "ticketing_purchase_limit_overrides_reason_check"

    add_index :ticketing_purchase_limit_overrides,
      :registration_id,
      unique: true,
      name: "idx_ticketing_purchase_limit_overrides_registration"
    add_index :ticketing_purchase_limit_overrides,
      :idempotency_key,
      unique: true,
      name: "idx_ticketing_purchase_limit_overrides_idempotency"

    add_foreign_key :ticketing_purchase_limit_overrides,
      :ticketing_registrations,
      column: :registration_id
    add_foreign_key :ticketing_purchase_limit_overrides,
      :ticketing_ticket_types,
      column: :ticket_type_id
    add_foreign_key :ticketing_purchase_limit_overrides,
      :core_users,
      column: :user_id
    add_foreign_key :ticketing_purchase_limit_overrides,
      :events_event_dates,
      column: :scope_event_date_id
    add_foreign_key :ticketing_purchase_limit_overrides,
      :core_users,
      column: :approved_by_id
  end
end
