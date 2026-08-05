# frozen_string_literal: true

class CreateCatalogVenueCapacityReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_venue_capacity_reservations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :reservation_group_id, null: false
      t.uuid :event_date_id, null: false
      t.uuid :event_product_id, null: false
      t.uuid :registration_id
      t.uuid :order_item_id
      t.integer :quantity_people, null: false
      t.string :status, null: false, default: "held"
      t.timestamptz :expires_at
      t.timestamptz :committed_at
      t.timestamptz :released_at
      t.string :request_fingerprint, limit: 64, null: false

      t.timestamps
    end

    add_foreign_key :catalog_venue_capacity_reservations, :events_event_dates,
                    column: :event_date_id
    add_foreign_key :catalog_venue_capacity_reservations, :catalog_event_products,
                    column: :event_product_id

    add_check_constraint :catalog_venue_capacity_reservations,
      "quantity_people > 0",
      name: "catalog_venue_capacity_reservations_quantity_check"
    add_check_constraint :catalog_venue_capacity_reservations,
      "status IN ('held','processing','committed','released','expired')",
      name: "catalog_venue_capacity_reservations_status_check"
    add_check_constraint :catalog_venue_capacity_reservations,
      "NOT (registration_id IS NOT NULL AND order_item_id IS NOT NULL)",
      name: "catalog_venue_capacity_reservations_owner_check"
    add_check_constraint :catalog_venue_capacity_reservations,
      "request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "catalog_venue_capacity_reservations_fingerprint_check"
    add_check_constraint :catalog_venue_capacity_reservations,
      "status IN ('committed','released','expired') OR expires_at IS NOT NULL",
      name: "catalog_venue_capacity_reservations_expiry_check"

    add_index :catalog_venue_capacity_reservations, %i[reservation_group_id event_date_id],
              unique: true,
              name: "idx_venue_capacity_reservations_on_group_and_date"
    add_index :catalog_venue_capacity_reservations, :event_date_id
    add_index :catalog_venue_capacity_reservations, :event_product_id
    add_index :catalog_venue_capacity_reservations, :registration_id
    add_index :catalog_venue_capacity_reservations, :order_item_id
    add_index :catalog_venue_capacity_reservations, %i[status expires_at],
              name: "idx_venue_capacity_reservations_on_status_and_expires"
  end
end
