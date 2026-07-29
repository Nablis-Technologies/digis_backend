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

        Catalog::ProductInventory.find_each do |inv|
          total_checked += 1
          expected_held = inv.inventory_reservations.active.sum(:quantity)

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

        success(
          discrepancies: discrepancies,
          total_checked: total_checked,
          total_discrepancies: total_discrepancies
        )
      end
    end
  end
end
