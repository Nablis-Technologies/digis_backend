# frozen_string_literal: true

module Catalog
  module Inventory
    # Locks inventory rows and creates held reservations. Checks product
    # capacity per inventory and venue capacity per date. Idempotent through
    # reservation_group_id — concurrent callers are serialized by the row lock.
    class Reserve < Core::BaseService
      def initialize(product:, event_date_ids: [], package_quantity:, admissions_per_unit:, owner: nil, reservation_group_id:, expires_at:)
        @product = product
        @event_date_ids = event_date_ids
        @package_quantity = package_quantity
        @admissions_per_unit = admissions_per_unit
        @owner = owner
        @reservation_group_id = reservation_group_id
        @expires_at = expires_at
      end

      def call
        ActiveRecord::Base.transaction do
          inventories = Catalog::ProductInventory.where(event_product_id: @product.id)
            .includes(:event_product)
            .order(:id)
            .lock!

          existing = Catalog::InventoryReservation.where(reservation_group_id: @reservation_group_id).lock.to_a
          return success(existing) if existing.present?

          return failure_i18n("catalog.inventory.errors.capacity_exceeded",
                               product_name: @product.name) if insufficient_product_capacity?(inventories)

          if @event_date_ids.present?
            dates = Events::EventDate.where(id: @event_date_ids).order(:id).lock!
            if insufficient_venue_capacity?(dates)
              raise Core::Error, I18n.t("catalog.inventory.errors.venue_capacity_exceeded")
            end
          end

          reservations = inventories.filter_map do |inv|
            held = inv.held_count
            ttl = inv.held_count + inv.sold_count
            remaining = inv.capacity - ttl
            qty = [ remaining, @package_quantity ].min
            next if qty.zero?

            inv.update!(held_count: held + qty)

            Catalog::InventoryReservation.create!(
              product_inventory: inv,
              registration_id: @owner&.respond_to?(:id) ? @owner.id : nil,
              order_item_id: nil,
              reservation_group_id: @reservation_group_id,
              quantity: qty,
              admissions_per_unit: @admissions_per_unit,
              status: "held",
              expires_at: @expires_at
            )
          end

          if reservations.empty? && inventories.any?
            return failure_i18n("catalog.inventory.errors.capacity_exceeded",
                                 product_name: @product.name)
          end

          if @event_date_ids.present?
            dates.each do |date|
              people = @package_quantity * @admissions_per_unit
              date.update!(held_venue_count: date.held_venue_count + people)
            end
          end

          success(reservations)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def insufficient_product_capacity?(inventory_rows)
        return false if inventory_rows.empty?

        inventory_rows.any? do |inv|
          (inv.held_count + inv.sold_count + @package_quantity) > inv.capacity
        end
      end

      def insufficient_venue_capacity?(dates)
        dates.any? do |date|
          next false if date.venue_capacity.blank?

          people = @package_quantity * @admissions_per_unit
          (date.held_venue_count + date.issued_venue_count + people) > date.venue_capacity
        end
      end
    end
  end
end
