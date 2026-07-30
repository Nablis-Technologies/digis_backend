# frozen_string_literal: true

module Catalog
  module Inventory
    # Batch expiry for timed-out reservation groups. Processes groups in
    # batches of BATCH_SIZE, acquiring the advisory lock per group so
    # concurrent workers never double-expire. Validates all rows are still
    # active and still past their expires_at before mutating counters.
    class Expire < Core::BaseService
      BATCH_SIZE = 100

      def call
        now = Time.current
        candidate_group_ids(now).each_slice(BATCH_SIZE).sum do |group_ids|
          group_ids.sum { |group_id| expire_group(group_id, now:) }
        end.then { |count| success(count) }
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def candidate_group_ids(now)
        inventory_groups = Catalog::InventoryReservation.active
          .where("expires_at < ?", now)
          .distinct
          .pluck(:reservation_group_id)
        venue_groups = Catalog::VenueCapacityReservation.active
          .where("expires_at < ?", now)
          .distinct
          .pluck(:reservation_group_id)

        (inventory_groups + venue_groups).uniq.sort
      end

      def expire_group(group_id, now:)
        ActiveRecord::Base.transaction do
          group = ReservationGroupLock.acquire!(group_id)
          reservations = group.reservations
          next 0 if reservations.empty? || reservations.all?(&:expired?)

          unless reservations.all?(&:active?)
            raise Core::Error, "Reservation group cannot expire from mixed or terminal states"
          end
          next 0 unless reservations.all? { |reservation| reservation.expires_at.present? && reservation.expires_at < now }

          inventory_quantities = inventory_quantities(group.inventory_reservations)
          venue_quantities = venue_quantities(group.venue_reservations)
          group.validate_held_counters!(inventory_quantities, venue_quantities)

          inventories = group.inventories.index_by(&:id)
          inventory_quantities.each do |inventory_id, quantity|
            inventory = inventories.fetch(inventory_id)
            inventory.update!(held_count: inventory.held_count - quantity)
          end
          dates = group.event_dates.index_by(&:id)
          venue_quantities.each do |event_date_id, quantity|
            event_date = dates.fetch(event_date_id)
            event_date.update!(held_venue_count: event_date.held_venue_count - quantity)
          end

          reservations.each do |reservation|
            reservation.update!(status: "expired", released_at: now)
          end

          reservations.size
        end
      end

      def inventory_quantities(reservations)
        reservations.each_with_object(Hash.new(0)) do |reservation, totals|
          totals[reservation.product_inventory_id] += reservation.quantity
        end
      end

      def venue_quantities(reservations)
        reservations.each_with_object(Hash.new(0)) do |reservation, totals|
          totals[reservation.event_date_id] += reservation.quantity_people
        end
      end
    end
  end
end
