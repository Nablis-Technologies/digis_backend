# frozen_string_literal: true

class CreateTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_tickets, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :event_product_id, null: false
      t.uuid :registration_id
      t.uuid :order_item_id
      t.integer :unit_number, null: false
      t.integer :admissions_per_unit_snapshot, limit: 2, null: false
      t.uuid :owner_user_id, null: false
      t.string :current_acquisition_type, null: false
      t.uuid :current_acquisition_order_item_id
      t.bigint :current_acquisition_product_value_minor, null: false, default: 0
      t.string :current_acquisition_currency, limit: 3, null: false
      t.integer :completed_resale_count, limit: 2, null: false, default: 0
      t.string :credential_mode, null: false, default: "group"
      t.integer :credential_version, null: false, default: 1
      t.uuid :current_credential_generation_id
      t.string :status, null: false, default: "active"
      t.timestamptz :issued_at, null: false
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_check_constraint :ticketing_tickets,
      "unit_number > 0 AND admissions_per_unit_snapshot > 0 AND " \
        "completed_resale_count >= 0 AND credential_version > 0",
      name: "ticketing_tickets_positive_values_check"
    add_check_constraint :ticketing_tickets,
      "current_acquisition_product_value_minor >= 0",
      name: "ticketing_tickets_acquisition_value_check"
    add_check_constraint :ticketing_tickets,
      "current_acquisition_currency ~ '^[A-Z]{3}$'",
      name: "ticketing_tickets_currency_check"
    add_check_constraint :ticketing_tickets,
      "credential_mode IN ('group','delegated')",
      name: "ticketing_tickets_credential_mode_check"
    add_check_constraint :ticketing_tickets,
      "status IN ('active','suspended','refunded','void')",
      name: "ticketing_tickets_status_check"
    add_check_constraint :ticketing_tickets,
      "registration_id IS NOT NULL OR order_item_id IS NOT NULL",
      name: "ticketing_tickets_source_check"
    add_check_constraint :ticketing_tickets,
      "((current_acquisition_type IN ('primary_purchase','resale_purchase') AND " \
        "current_acquisition_order_item_id IS NOT NULL) OR " \
        "(current_acquisition_type IN ('free_registration','free_transfer','complimentary') AND " \
        "current_acquisition_order_item_id IS NULL))",
      name: "ticketing_tickets_acquisition_source_check"
    add_check_constraint :ticketing_tickets,
      "current_acquisition_type IN " \
        "('primary_purchase','resale_purchase','free_registration','free_transfer','complimentary')",
      name: "ticketing_tickets_acquisition_type_check"

    add_index :ticketing_tickets, %i[order_item_id unit_number],
      unique: true,
      where: "order_item_id IS NOT NULL",
      name: "idx_ticketing_tickets_order_item_unit"
    add_index :ticketing_tickets, %i[registration_id unit_number],
      unique: true,
      where: "registration_id IS NOT NULL",
      name: "idx_ticketing_tickets_registration_unit"
    add_index :ticketing_tickets, %i[event_id status]
    add_index :ticketing_tickets, :owner_user_id
    add_index :ticketing_tickets, :current_credential_generation_id, unique: true

    add_foreign_key :ticketing_tickets, :events_events, column: :event_id
    add_foreign_key :ticketing_tickets, :catalog_event_products, column: :event_product_id
    add_foreign_key :ticketing_tickets, :ticketing_registrations, column: :registration_id
    add_foreign_key :ticketing_tickets, :orders_order_items, column: :order_item_id
    add_foreign_key :ticketing_tickets, :orders_order_items,
      column: :current_acquisition_order_item_id
    add_foreign_key :ticketing_tickets, :core_users, column: :owner_user_id
  end
end
