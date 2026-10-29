# frozen_string_literal: true

module Catalog
  module Public
    # Projects one offer's read-only sale, date, and capacity state. Checkout
    # remains authoritative; this resolver only evaluates preloaded snapshots.
    class OfferAvailability
      def self.call(product:, at:, capacity_snapshot:, date_snapshot:)
        new(product:, at:, capacity_snapshot:, date_snapshot:).call
      end

      def initialize(product:, at:, capacity_snapshot:, date_snapshot:)
        @product = product
        @at = at.to_time
        @capacity_snapshot = capacity_snapshot
        @date_snapshot = date_snapshot
      end

      def call
        return "unavailable" if product.ticket? && product.ticket_type.blank?

        candidates = eligible_date_sets
        return "no_eligible_dates" if candidates.empty?

        window_state = sales_window_state
        return window_state unless window_state == "available"
        return "unavailable" unless usable_price?

        capacity_state_for(candidates)
      end

      private

      attr_reader :product, :at, :capacity_snapshot, :date_snapshot

      def eligible_date_sets
        candidate_date_sets.select do |date_ids|
          next true unless product.credential_bearing?

          date_snapshot.eligible?(date_ids)
        end
      end

      def candidate_date_sets
        unless product.credential_bearing?
          return [ [] ] unless product.inventory_mode.in?(%w[per_date event_wide_and_per_date])

          return capacity_snapshot.event_date_rows.filter_map do |date|
            [ date.id ] if date.status == "scheduled" && date.starts_at > at
          end
        end

        accesses = product.product_accesses.to_a
        if product.ticket_type.date_selection == "choose_one"
          return accesses.map { |access| [ access.event_date_id ] }.uniq
        end

        [ product.ticket_type.admission_line(
          product:, selected_event_date_id: nil, package_quantity: product.min_per_order,
          admissions_per_unit: product.ticket_type.admissions_per_unit
        ).event_date_ids ]
      end

      def capacity_state_for_date(date_ids)
        plan = Catalog::Inventory::Capacity.plan_from_snapshot!(line: line_for(date_ids), snapshot: capacity_snapshot)
        violation = Catalog::Inventory::Capacity.evaluate(
          plan:, snapshot: capacity_snapshot
        )
        return "sold_out" if Catalog::Inventory::Capacity.capacity_exhausted?(violation)

        "available"
      rescue Core::Error
        "unavailable"
      end

      def capacity_state_for(candidates)
        saw_sold_out = false
        saw_unavailable = false

        candidates.each do |date_ids|
          state = capacity_state_for_date(date_ids)
          return "available" if state == "available"

          saw_unavailable ||= state == "unavailable"
          saw_sold_out ||= state == "sold_out"
        end

        return "unavailable" if saw_unavailable
        return "sold_out" if saw_sold_out

        "unavailable"
      end

      def line_for(date_ids)
        if product.ticket?
          selected_event_date_id = product.ticket_type.date_selection == "choose_one" ? date_ids.first : nil
          return product.ticket_type.admission_line(
            product:, selected_event_date_id:, package_quantity: product.min_per_order,
            admissions_per_unit: product.ticket_type.admissions_per_unit
          )
        end

        Catalog::Inventory::Line.new(
          product:,
          event_date_ids: date_ids,
          venue_event_date_ids: [],
          package_quantity: product.min_per_order,
          admissions_per_unit: 1
        )
      end

      def sales_window_state
        case Catalog::Products::SalesWindow.error_key(product, at:)
        when :sales_not_started then "coming_soon"
        when :sales_ended then "sales_closed"
        else "available"
        end
      end

      def usable_price?
        price_at = [ at, product.sales_start_at ].compact.max
        product.prices.to_a.any? { |price| Catalog::Public::PriceWindow.active?(price, at: price_at) }
      end
    end
  end
end
