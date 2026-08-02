# frozen_string_literal: true

module Catalog
  module Inventory
    # Acquires a deterministic lock ordering for all rows related to a
    # reservation group: advisory lock → inventories (sorted by id) →
    # event_dates (sorted by id) → inventory_reservations (sorted by id) →
    # venue_capacity_reservations (sorted by id). Returns a Group Data.define
    # with accessors for each collection. Prevents deadlocks by locking rows
    # in a consistent global order across Reserve, Commit, Release, and Expire.
    class ReservationGroupLock
      Group = Data.define(
        :inventories,
        :event_dates,
        :inventory_reservations,
        :venue_reservations
      ) do
        def reservations
          inventory_reservations + venue_reservations
        end

        def validate_held_counters!(inventory_quantities, venue_quantities)
          inv_index = inventories.index_by(&:id)
          date_index = event_dates.index_by(&:id)

          inventory_quantities.each do |inventory_id, quantity|
            if inv_index.fetch(inventory_id).held_count < quantity
              raise Core::Error, I18n.t("catalog.inventory.errors.inventory_held_count_drift")
            end
          end
          venue_quantities.each do |event_date_id, quantity|
            if date_index.fetch(event_date_id).held_venue_count < quantity
              raise Core::Error, I18n.t("catalog.inventory.errors.venue_held_count_drift")
            end
          end
        end
      end

      def self.acquire!(reservation_group_id, inventory_ids: [], event_date_ids: [])
        Core::Database::AdvisoryLock.acquire!(
          "catalog-inventory-reservation-group",
          reservation_group_id
        )

        existing_inventory_ids = Catalog::InventoryReservation
          .by_group(reservation_group_id)
          .distinct
          .pluck(:product_inventory_id)
        existing_date_ids = Catalog::VenueCapacityReservation
          .by_group(reservation_group_id)
          .distinct
          .pluck(:event_date_id)

        inventories = Catalog::ProductInventory
          .includes(:event_product)
          .where(id: (Array(inventory_ids) + existing_inventory_ids).uniq)
          .order(:id)
          .lock
          .to_a
        event_dates = Events::EventDate
          .where(id: (Array(event_date_ids) + existing_date_ids).uniq)
          .order(:id)
          .lock
          .to_a
        inventory_reservations = Catalog::InventoryReservation
          .by_group(reservation_group_id)
          .order(:id)
          .lock
          .to_a
        venue_reservations = Catalog::VenueCapacityReservation
          .by_group(reservation_group_id)
          .order(:id)
          .lock
          .to_a

        Group.new(
          inventories:,
          event_dates:,
          inventory_reservations:,
          venue_reservations:
        )
      end
    end
  end
end
