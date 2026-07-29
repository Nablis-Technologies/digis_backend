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
        @request = ReservationRequest.new(
          product:,
          event_date_ids:,
          venue_event_date_ids:,
          package_quantity:,
          admissions_per_unit:,
          owner:,
          expires_at:
        )
      end

      def call
        ActiveRecord::Base.transaction do
          validate_product_active!
          validate_sales_window!
          validate_dates_belong_to_event!
          validate_request_values!

          requested_inventories = resolve_requested_inventories!
          group = ReservationGroupLock.acquire!(
            @reservation_group_id,
            inventory_ids: requested_inventories.map(&:id),
            event_date_ids: @request.venue_event_date_ids
          )

          replay = replay_result(group)
          return replay if replay

          inventories = select_requested_inventories(group, requested_inventories)
          dates = select_requested_dates(group)
          validate_product_capacity!(inventories)
          validate_venue_capacity!(dates)

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
        raise Core::Error, "Product is not active" unless @product.status == "active"
      end

      def validate_sales_window!
        now = Time.current
        raise Core::Error, "Sales have not started yet" if @product.sales_start_at.present? && now < @product.sales_start_at
        raise Core::Error, "Sales have ended" if @product.sales_end_at.present? && now > @product.sales_end_at
      end

      def validate_dates_belong_to_event!
        requested_ids = (@request.event_date_ids + @request.venue_event_date_ids).uniq
        return if requested_ids.empty?
        unless (@request.venue_event_date_ids - @request.event_date_ids).empty?
          raise Core::Error, "Venue dates must be included in the selected event dates"
        end

        event_date_ids = @product.event.event_dates
          .where(id: requested_ids)
          .pluck(:id)
          .map(&:to_s)
        missing = requested_ids - event_date_ids
        return if missing.empty?

        raise Core::Error, "Event date(s) #{missing.join(', ')} do not belong to the product's event"
      end

      def validate_request_values!
        unless @request.package_quantity.is_a?(Integer) && @request.package_quantity.positive?
          raise Core::Error, "Package quantity must be a positive integer"
        end
        unless @request.admissions_per_unit.is_a?(Integer) && @request.admissions_per_unit.positive?
          raise Core::Error, "Admissions per unit must be a positive integer"
        end
      end

      def resolve_requested_inventories!
        scope = Catalog::ProductInventory.where(event_product_id: @product.id)
        global = scope.find_by(event_date_id: nil)
        dated = scope.where(event_date_id: @request.event_date_ids).to_a
        dated_ids = dated.map { |inventory| inventory.event_date_id.to_s }
        missing_date_ids = @request.event_date_ids - dated_ids

        case @product.inventory_mode
        when "unlimited"
          []
        when "event_wide"
          raise_missing_inventory! unless global
          [ global ]
        when "per_date"
          raise_missing_inventory! if @request.event_date_ids.empty? || missing_date_ids.any?
          dated
        when "event_wide_and_per_date"
          raise_missing_inventory! unless global
          raise_missing_inventory! if @request.event_date_ids.empty? || missing_date_ids.any?
          [ global, *dated ]
        else
          raise Core::Error, "Unsupported inventory mode: #{@product.inventory_mode}"
        end
      end

      def raise_missing_inventory!
        raise Core::Error, I18n.t("catalog.inventory.errors.no_inventory_for_requested_dates")
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
          failure(Core::Error.new("Reservation group was already used for a different request"))
        end
      end

      def select_requested_inventories(group, requested)
        requested_ids = requested.map(&:id)
        group.inventories.select { |inventory| requested_ids.include?(inventory.id) }
      end

      def select_requested_dates(group)
        group.event_dates.select { |date| @request.venue_event_date_ids.include?(date.id.to_s) }
      end

      def validate_product_capacity!(inventories)
        exceeded = inventories.any? do |inventory|
          inventory.held_count + inventory.sold_count + @request.package_quantity > inventory.capacity
        end
        return unless exceeded

        raise Core::Error, I18n.t("catalog.inventory.errors.capacity_exceeded", product_name: @product.name)
      end

      def validate_venue_capacity!(dates)
        people = venue_quantity
        exceeded = dates.any? do |date|
          date.venue_capacity.present? &&
            date.held_venue_count + date.issued_venue_count + people > date.venue_capacity
        end
        return unless exceeded

        raise Core::Error, I18n.t("catalog.inventory.errors.venue_capacity_exceeded")
      end

      def create_inventory_reservations!(inventories)
        inventories.map do |inventory|
          inventory.update!(held_count: inventory.held_count + @request.package_quantity)
          Catalog::InventoryReservation.create!(
            {
              product_inventory: inventory,
              reservation_group_id: @reservation_group_id,
              quantity: @request.package_quantity,
              admissions_per_unit: @request.admissions_per_unit,
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
        @request.package_quantity * @request.admissions_per_unit
      end
    end
  end
end
