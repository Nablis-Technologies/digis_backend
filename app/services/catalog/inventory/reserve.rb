# frozen_string_literal: true

module Catalog
  module Inventory
    # Holds capacity for a product + optional venue dates. Idempotent per
    # reservation_group_id — replays return the existing reservations without
    # mutating counters. Uses ReservationGroupLock for safe concurrency.
    class Reserve < Core::BaseService
      def initialize(product:, event_date_ids: [], venue_event_date_ids: event_date_ids,
        package_quantity:, admissions_per_unit:, owner: nil, reservation_group_id:, expires_at:)
        @product = product
        @reservation_group_id = reservation_group_id
        @line = Line.new(
          product:,
          event_date_ids:,
          venue_event_date_ids:,
          package_quantity:,
          admissions_per_unit:
        )
        @request = ReservationRequest.new(
          line: @line,
          owner:,
          expires_at:
        )
      end

      def call
        ActiveRecord::Base.transaction do
          validate_product_active!
          validate_sales_window!
          plan = Capacity.plan!(@line)
          group = ReservationGroupLock.acquire!(
            @reservation_group_id,
            inventory_ids: plan.inventory_ids,
            event_date_ids: @line.venue_event_date_ids
          )

          replay = replay_result(group)
          return replay if replay

          inventories = select_requested_inventories(group, plan.inventory_ids)
          dates = select_requested_dates(group)
          validate_capacity!(group, plan)

          reservations = create_inventory_reservations!(inventories)
          reservations.concat(create_venue_reservations!(dates))
          success(reservations)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def validate_product_active!
        raise Core::Error, I18n.t("catalog.inventory.errors.product_not_active") unless @product.status == "active"
      end

      def validate_sales_window!
        error_key = Catalog::Products::SalesWindow.error_key(@product)
        raise Core::Error, I18n.t("catalog.inventory.errors.#{error_key}") if error_key
      end

      def validate_capacity!(group, plan)
        violation = Capacity.violation(
          plan:,
          inventory_rows: group.inventories,
          event_date_rows: group.event_dates
        )
        Capacity.raise_on_violation!(violation, product: @product)
      end

      def replay_result(group)
        return nil if group.reservations.empty?

        fingerprints = group.reservations.map(&:request_fingerprint).uniq
        inventories = group.inventories.index_by(&:id)
        product_ids = group.inventory_reservations.map do |reservation|
          inventories.fetch(reservation.product_inventory_id).event_product_id
        end
        product_ids.concat(group.venue_reservations.map(&:event_product_id))

        if fingerprints == [ @request.fingerprint ] && product_ids.map(&:to_s).uniq == [ @product.id.to_s ]
          success(group.reservations)
        else
          failure_i18n("catalog.inventory.errors.reservation_group_idempotency_conflict")
        end
      end

      def select_requested_inventories(group, requested_ids)
        group.inventories.select { |inventory| requested_ids.include?(inventory.id) }
      end

      def select_requested_dates(group)
        group.event_dates.select { |date| @line.venue_event_date_ids.include?(date.id.to_s) }
      end

      def create_inventory_reservations!(inventories)
        inventories.map do |inventory|
          inventory.update!(held_count: inventory.held_count + @line.package_quantity)
          Catalog::InventoryReservation.create!(
            {
              product_inventory: inventory,
              reservation_group_id: @reservation_group_id,
              quantity: @line.package_quantity,
              admissions_per_unit: @line.admissions_per_unit,
              status: "held",
              expires_at: @request.expires_at,
              request_fingerprint: @request.fingerprint
            }.merge(@request.owner_attributes)
          )
        end
      end

      def create_venue_reservations!(dates)
        dates.map do |date|
          date.update!(held_venue_count: date.held_venue_count + venue_quantity)
          Catalog::VenueCapacityReservation.create!(
            {
              event_date: date,
              event_product: @product,
              reservation_group_id: @reservation_group_id,
              quantity_people: venue_quantity,
              status: "held",
              expires_at: @request.expires_at,
              request_fingerprint: @request.fingerprint
            }.merge(@request.owner_attributes)
          )
        end
      end

      def venue_quantity
        Capacity.venue_quantity(@line)
      end
    end
  end
end
