# frozen_string_literal: true

module Catalog
  module Inventory
    # Releases a held/processing reservation group, restoring capacity to the
    # available pool. Decrements both inventory held_count and event-date
    # held_venue_count. Idempotent — already-released groups are no-ops.
    class Release < Core::BaseService
      def initialize(reservation_group_id:)
        @reservation_group_id = reservation_group_id
      end

      def call
        ActiveRecord::Base.transaction do
          group = ReservationGroupLock.acquire!(@reservation_group_id)
          reservations = group.reservations
          return group_not_found if reservations.empty?
          return success(reservations) if reservations.all?(&:released?)
          return success(reservations) if reservations.all? { |reservation| reservation.released? || reservation.expired? }

          validate_all_active!(reservations)
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

          now = Time.current
          reservations.each do |reservation|
            reservation.update!(status: "released", released_at: now)
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

      def validate_all_active!(reservations)
        return if reservations.all?(&:active?)

        raise Core::Error, I18n.t(
          "catalog.inventory.errors.reservation_group_invalid_transition", target: "released"
        )
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
