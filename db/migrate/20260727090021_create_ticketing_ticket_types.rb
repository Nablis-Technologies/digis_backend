# frozen_string_literal: true

class CreateTicketingTicketTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_ticket_types, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_product_id, null: false
      t.string :approval_mode, null: false, default: "automatic"
      t.string :audience, null: false
      t.string :date_selection, null: false
      t.boolean :waitlist_enabled, null: false, default: false
      t.boolean :transferable
      t.integer :transfer_cutoff_seconds_before_start, null: false, default: 0
      t.integer :admissions_per_unit, null: false, default: 1
      t.boolean :delegation_enabled, null: false, default: false
      t.string :delegation_validation_mode, null: false, default: "offline_allowed"
      t.string :entry_validation_mode, null: false, default: "qr"
      t.integer :max_packages_per_user
      t.boolean :resale_enabled, null: false, default: false
      t.integer :resale_cutoff_seconds_before_start, null: false, default: 0
      t.string :resale_price_cap_type
      t.bigint :resale_fixed_cap_minor
      t.string :resale_fixed_cap_currency, limit: 3
      t.integer :resale_percentage_cap_bps
      t.integer :max_completed_resales, null: false, default: 1

      t.timestamps
    end

    add_check_constraint :ticketing_ticket_types,
      "approval_mode IN ('automatic','manual')",
      name: "ticketing_ticket_types_approval_mode_check"
    add_check_constraint :ticketing_ticket_types,
      "audience IN ('public','access_code','invitation','code_or_invitation')",
      name: "ticketing_ticket_types_audience_check"
    add_check_constraint :ticketing_ticket_types,
      "date_selection IN ('fixed','choose_one')",
      name: "ticketing_ticket_types_date_selection_check"
    add_check_constraint :ticketing_ticket_types,
      "delegation_validation_mode IN ('offline_allowed','online_required')",
      name: "ticketing_ticket_types_delegation_mode_check"
    add_check_constraint :ticketing_ticket_types,
      "entry_validation_mode IN ('qr','qr_and_id')",
      name: "ticketing_ticket_types_entry_mode_check"
    add_check_constraint :ticketing_ticket_types,
      "transfer_cutoff_seconds_before_start >= 0",
      name: "ticketing_ticket_types_transfer_cutoff_check"
    add_check_constraint :ticketing_ticket_types,
      "admissions_per_unit > 0",
      name: "ticketing_ticket_types_admissions_check"
    add_check_constraint :ticketing_ticket_types,
      "resale_cutoff_seconds_before_start >= 0",
      name: "ticketing_ticket_types_resale_cutoff_check"
    add_check_constraint :ticketing_ticket_types,
      "max_completed_resales > 0",
      name: "ticketing_ticket_types_max_resales_check"
    add_check_constraint :ticketing_ticket_types,
      "max_packages_per_user IS NULL OR max_packages_per_user > 0",
      name: "ticketing_ticket_types_max_per_user_check"
    add_check_constraint :ticketing_ticket_types,
      "(resale_price_cap_type IS NULL) OR " \
        "(resale_price_cap_type = 'fixed' AND resale_fixed_cap_minor IS NOT NULL " \
        "AND resale_fixed_cap_currency IS NOT NULL AND resale_percentage_cap_bps IS NULL) OR " \
        "(resale_price_cap_type = 'percentage' AND resale_percentage_cap_bps IS NOT NULL " \
        "AND resale_fixed_cap_minor IS NULL AND resale_fixed_cap_currency IS NULL)",
      name: "ticketing_ticket_types_resale_cap_check"

    add_index :ticketing_ticket_types, :event_product_id, unique: true
    add_foreign_key :ticketing_ticket_types, :catalog_event_products, column: :event_product_id
  end
end
