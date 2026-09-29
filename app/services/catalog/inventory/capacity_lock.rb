# frozen_string_literal: true

module Catalog
  module Inventory
    # Locks capacity counters in the ordering shared by availability checks and
    # reservation lifecycle commands: product inventories, then event dates.
    class CapacityLock
      Rows = Data.define(:inventories, :event_dates)

      def self.acquire!(inventory_ids:, event_date_ids:)
        Rows.new(
          inventories: lock_inventories(inventory_ids),
          event_dates: lock_event_dates(event_date_ids)
        )
      end

      def self.lock_inventories(ids)
        Catalog::ProductInventory.includes(:event_product)
          .where(id: Array(ids).uniq).order(:id).lock.to_a
      end
      private_class_method :lock_inventories

      def self.lock_event_dates(ids)
        Events::EventDate.where(id: Array(ids).uniq).order(:id).lock.to_a
      end
      private_class_method :lock_event_dates
    end
  end
end
