# frozen_string_literal: true

module Catalog
  module Inventory
    # Transitions a held reservation to committed. Decrements held_count and
    # increments sold_count on the inventory. Updates venue issued counts
    # using quantity × admissions_per_unit. Idempotent on repeated calls.
    class Commit < Core::BaseService
      def initialize(reservation:)
        @reservation = reservation
      end

      def call
        ActiveRecord::Base.transaction do
          reservation = Catalog::InventoryReservation.lock.find(@reservation.id)
          return success(reservation) if reservation.committed?

          unless reservation.held?
            return failure_i18n("catalog.inventory_reservation.errors.invalid_status_transition",
                                 from: reservation.status, to: "committed")
          end

          inv = Catalog::ProductInventory.lock.find(reservation.product_inventory_id)
          inv.update!(
            held_count: inv.held_count - reservation.quantity,
            sold_count: inv.sold_count + reservation.quantity
          )

          reservation.update!(
            status: "committed",
            committed_at: Time.current
          )

          update_venue_counts(reservation, :commit)

          success(reservation)
        end
      rescue ActiveRecord::RecordNotFound
        failure_i18n("catalog.inventory.errors.reservation_not_found")
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def update_venue_counts(reservation, _action)
        inv = reservation.product_inventory
        return unless inv.event_date_id

        date = Events::EventDate.find(inv.event_date_id)
        people = reservation.quantity * reservation.admissions_per_unit
        date.update!(
          held_venue_count: date.held_venue_count - people,
          issued_venue_count: date.issued_venue_count + people
        )
      end
    end
  end
end
