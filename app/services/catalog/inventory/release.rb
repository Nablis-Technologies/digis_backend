# frozen_string_literal: true

module Catalog
  module Inventory
    # Transitions a held reservation to released. Decrements held_count and
    # releases venue capacity. Idempotent on repeated calls.
    class Release < Core::BaseService
      def initialize(reservation:)
        @reservation = reservation
      end

      def call
        ActiveRecord::Base.transaction do
          reservation = Catalog::InventoryReservation.lock.find(@reservation.id)
          return success(reservation) if reservation.released?

          unless reservation.active?
            return failure_i18n("catalog.inventory_reservation.errors.invalid_status_transition",
                                 from: reservation.status, to: "released")
          end

          inv = Catalog::ProductInventory.lock.find(reservation.product_inventory_id)
          inv.update!(held_count: inv.held_count - reservation.quantity)

          reservation.update!(
            status: "released",
            released_at: Time.current
          )

          release_venue_capacity(reservation)

          success(reservation)
        end
      rescue ActiveRecord::RecordNotFound
        failure_i18n("catalog.inventory.errors.reservation_not_found")
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def release_venue_capacity(reservation)
        inv = reservation.product_inventory
        return unless inv.event_date_id

        date = Events::EventDate.find(inv.event_date_id)
        people = reservation.quantity * reservation.admissions_per_unit
        date.update!(held_venue_count: date.held_venue_count - people)
      end
    end
  end
end
