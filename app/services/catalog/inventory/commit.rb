# frozen_string_literal: true

module Catalog
  module Inventory
    # Converts held/processing reservations to committed. Transitions the
    # entire reservation group atomically — moves quantity from held_count
    # to sold_count and held_venue_count to issued_venue_count. Replay-safe:
    # a group already committed returns success with no mutation.
    class Commit < Core::BaseService
      def initialize(reservation_group_id:)
        @reservation_group_id = reservation_group_id
      end

      def call
        ActiveRecord::Base.transaction do
          group = ReservationGroupLock.acquire!(@reservation_group_id)
          reservations = group.reservations
          return group_not_found if reservations.empty?
          return success(reservations) if reservations.all?(&:committed?)

          validate_all_active!(reservations, target: "committed")
          inventory_quantities = inventory_quantities(group.inventory_reservations)
          venue_quantities = venue_quantities(group.venue_reservations)
          group.validate_held_counters!(inventory_quantities, venue_quantities)

          inventory_quantities.each do |inventory_id, quantity|
            inventory = group.inventories.index_by(&:id).fetch(inventory_id)
            inventory.update!(
              held_count: inventory.held_count - quantity,
              sold_count: inventory.sold_count + quantity
            )
          end
          venue_quantities.each do |event_date_id, quantity|
            event_date = group.event_dates.index_by(&:id).fetch(event_date_id)
            event_date.update!(
              held_venue_count: event_date.held_venue_count - quantity,
              issued_venue_count: event_date.issued_venue_count + quantity
            )
          end

          now = Time.current
          reservations.each do |reservation|
            reservation.update!(status: "committed", committed_at: now)
          end

          success(reservations)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def group_not_found
        failure_i18n("catalog.inventory.errors.reservation_group_not_found", group_id: @reservation_group_id)
      end

      def validate_all_active!(reservations, target:)
        return if reservations.all?(&:active?)

        raise Core::Error, "Reservation group cannot transition to #{target} from mixed or terminal states"
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
