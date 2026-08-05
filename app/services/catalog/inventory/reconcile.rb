# frozen_string_literal: true

module Catalog
  module Inventory
    # Compares held_count against the sum of active reservation quantities.
    # Reports discrepancies for manual resolution — does not auto-correct.
    class Reconcile < Core::BaseService
      def initialize(threshold: 0)
        @threshold = threshold
      end

      def call
        discrepancies = []
        total_checked = 0
        total_discrepancies = 0
        expected_inventory_held = Catalog::InventoryReservation.active
          .group(:product_inventory_id)
          .sum(:quantity)
        expected_venue_held = Catalog::VenueCapacityReservation.active
          .group(:event_date_id)
          .sum(:quantity_people)
        expected_venue_issued = Catalog::VenueCapacityReservation
          .where(status: "committed")
          .group(:event_date_id)
          .sum(:quantity_people)

        Catalog::ProductInventory.find_each do |inv|
          total_checked += 1
          expected_held = expected_inventory_held.fetch(inv.id, 0)

          if (expected_held - inv.held_count).abs > @threshold
            discrepancies << {
              inventory_id: inv.id,
              event_product_id: inv.event_product_id,
              field: "held_count",
              expected: expected_held,
              actual: inv.held_count
            }
            total_discrepancies += 1
          end

          total = inv.held_count + inv.sold_count
          if total > inv.capacity
            discrepancies << {
              inventory_id: inv.id,
              event_product_id: inv.event_product_id,
              field: "capacity",
              expected: inv.capacity,
              actual: total
            }
            total_discrepancies += 1
          end
        end

        Events::EventDate.find_each do |event_date|
          total_checked += 1
          expected_held = expected_venue_held.fetch(event_date.id, 0)
          expected_issued = expected_venue_issued.fetch(event_date.id, 0)

          total_discrepancies += append_discrepancy!(
            discrepancies,
            event_date:,
            field: "held_venue_count",
            expected: expected_held,
            actual: event_date.held_venue_count
          )
          total_discrepancies += append_discrepancy!(
            discrepancies,
            event_date:,
            field: "issued_venue_count",
            expected: expected_issued,
            actual: event_date.issued_venue_count
          )
        end

        success(
          discrepancies: discrepancies,
          total_checked: total_checked,
          total_discrepancies: total_discrepancies
        )
      end

      private

      def append_discrepancy!(discrepancies, event_date:, field:, expected:, actual:)
        return 0 if (expected - actual).abs <= @threshold

        discrepancies << {
          event_date_id: event_date.id,
          event_id: event_date.event_id,
          field:,
          expected:,
          actual:
        }
        1
      end
    end
  end
end
