# frozen_string_literal: true

module Catalog
  module Inventory
    # Checks a batch of demand lines without writing holds or changing
    # counters. Plans are locked and evaluated in product order.
    class CheckAvailability < Core::BaseService
      Result = Data.define(:unavailable_product_ids)

      def initialize(lines:)
        @lines = Array(lines)
      end

      def call
        outcome = nil
        ActiveRecord::Base.transaction do
          plans = ordered_plans
          rows = lock_capacity_rows(plans)
          unavailable = evaluate(plans, rows)
          outcome = success(Result.new(unavailable_product_ids: unavailable))
        end
        outcome
      rescue Core::Error => error
        failure(error)
      end

      private

      def ordered_plans
        @lines.map { |line| Capacity.plan!(line) }.sort_by { |plan| plan.line.product.id.to_s }
      end

      def lock_capacity_rows(plans)
        CapacityLock.acquire!(
          inventory_ids: plans.flat_map(&:inventory_ids),
          event_date_ids: plans.flat_map { |plan| plan.line.venue_event_date_ids }
        )
      end

      def evaluate(plans, rows)
        simulated_inventory = Hash.new(0)
        simulated_venue = Hash.new(0)

        plans.filter_map do |plan|
          violation = Capacity.violation(
            plan:,
            inventory_rows: rows.inventories,
            event_date_rows: rows.event_dates,
            inventory_demand: simulated_inventory,
            venue_demand: simulated_venue
          )
          if Capacity.capacity_exhausted?(violation)
            plan.line.product.id.to_s
          else
            account_demand!(plan, simulated_inventory, simulated_venue)
            nil
          end
        end
      end

      def account_demand!(plan, simulated_inventory, simulated_venue)
        plan.inventory_ids.each { |id| simulated_inventory[id] += plan.line.package_quantity }
        plan.line.venue_event_date_ids.each do |id|
          simulated_venue[id] += Capacity.venue_quantity(plan.line)
        end
      end
    end
  end
end
