# frozen_string_literal: true

module Catalog
  module Inventory
    # Bulk-expires held reservations past their expires_at. Processes in
    # batches, decrementing held_count and releasing venue capacity.
    class Expire < Core::BaseService
      def call
        expired = Catalog::InventoryReservation.held
          .where("expires_at < ?", Time.current)
          .includes(:product_inventory)
        expired_count = 0

        expired.find_in_batches do |batch|
          group_ids = batch.map(&:id)
          inventories = Hash.new(0)
          venue_dates = Hash.new(0)

          batch.each do |res|
            inventories[res.product_inventory_id] += res.quantity
            inv = res.product_inventory
            if inv.event_date_id
              venue_dates[inv.event_date_id] += res.quantity * res.admissions_per_unit
            end
          end

          ActiveRecord::Base.transaction do
            inventories.each do |inv_id, qty|
              Catalog::ProductInventory.where(id: inv_id).update_all(
                [ "held_count = GREATEST(held_count - ?, 0)", qty ]
              )
            end

            venue_dates.each do |date_id, people|
              Events::EventDate.where(id: date_id).update_all(
                [ "held_venue_count = GREATEST(held_venue_count - ?, 0)", people ]
              )
            end

            Catalog::InventoryReservation.where(id: group_ids).update_all(
              status: "expired",
              released_at: Time.current
            )
          end

          expired_count += batch.size
        end

        success(expired_count)
      end
    end
  end
end
