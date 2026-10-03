# frozen_string_literal: true

module Catalog
  module Inventory
    # Validates a demand line, resolves its inventory pools, and assesses that
    # validated plan against the locked rows used by both read and write paths.
    class Capacity
      Plan = Data.define(:line, :inventory_ids) do
        def initialize(line:, inventory_ids:)
          super(
            line:,
            inventory_ids: Array(inventory_ids).map(&:to_s).uniq.sort.freeze
          )
        end
      end

      Snapshot = Data.define(
        :inventory_rows, :event_date_rows, :inventories_by_product_and_date,
        :inventories_by_id, :event_dates_by_id
      ) do
        def initialize(inventory_rows:, event_date_rows:)
          inventories = Array(inventory_rows)
          event_dates = Array(event_date_rows)
          super(
            inventory_rows: inventories,
            event_date_rows: event_dates,
            inventories_by_product_and_date: inventories.group_by do |row|
              [ row.event_product_id.to_s, row.event_date_id&.to_s ]
            end,
            inventories_by_id: inventories.index_by { |row| row.id.to_s },
            event_dates_by_id: event_dates.index_by { |row| row.id.to_s }
          )
        end
      end

      def self.plan!(line)
        validate_line!(line)

        inventories = Catalog::ProductInventory.where(event_product_id: line.product.id)
        global = inventories.find_by(event_date_id: nil)
        dated = inventories.where(event_date_id: line.event_date_ids).to_a
        Plan.new(line:, inventory_ids: inventory_ids_for!(line, global, dated))
      end

      # Builds the same validated capacity plan from rows already loaded by a
      # read-only discovery projection. This path deliberately takes no locks.
      def self.plan_from_snapshot!(line:, snapshot:)
        validate_line!(line, event_dates_by_id: snapshot.event_dates_by_id)

        product_id = line.product.id.to_s
        global = snapshot.inventories_by_product_and_date.fetch([ product_id, nil ], []).first
        dated = line.event_date_ids.filter_map do |date_id|
          snapshot.inventories_by_product_and_date.fetch([ product_id, date_id ], []).first
        end
        Plan.new(line:, inventory_ids: inventory_ids_for!(line, global, dated))
      end

      def self.evaluate(plan:, inventory_rows: nil, event_date_rows: nil, snapshot: nil,
        inventory_demand: {}, venue_demand: {})
        validate_plan!(plan)
        validate_line!(
          plan.line,
          event_date_rows: snapshot ? nil : event_date_rows,
          event_dates_by_id: snapshot&.event_dates_by_id
        )
        inventories = snapshot ? snapshot.inventories_by_id : Array(inventory_rows).index_by { |row| row.id.to_s }
        event_dates = snapshot ? snapshot.event_dates_by_id : Array(event_date_rows).index_by { |row| row.id.to_s }

        return :product_capacity if product_capacity_exceeded?(plan, inventories, inventory_demand)
        return :venue_capacity if venue_capacity_exceeded?(plan, event_dates, venue_demand)

        nil
      end

      def self.capacity_exhausted?(violation)
        case violation
        when nil then false
        when :product_capacity, :venue_capacity then true
        else invalid_violation!
        end
      end

      def self.raise_on_violation!(violation, product:)
        case violation
        when nil
          nil
        when :product_capacity
          raise Core::Error, I18n.t("catalog.inventory.errors.capacity_exceeded", product_name: product.name)
        when :venue_capacity
          raise Core::Error, I18n.t("catalog.inventory.errors.venue_capacity_exceeded")
        else
          invalid_violation!
        end
      end

      def self.venue_quantity(line)
        line.package_quantity * line.admissions_per_unit
      end

      def self.validate_line!(line, event_date_rows: nil, event_dates_by_id: nil)
        unless line.is_a?(Line)
          raise_capacity_error("invalid_capacity_request", "package_quantity_positive")
        end
        unless line.package_quantity.is_a?(Integer) && line.package_quantity.positive?
          raise_capacity_error("invalid_capacity_request", "package_quantity_positive")
        end
        unless line.admissions_per_unit.is_a?(Integer) && line.admissions_per_unit.positive?
          raise_capacity_error("invalid_capacity_request", "admissions_per_unit_positive")
        end
        if (line.venue_event_date_ids - line.event_date_ids).any?
          raise_capacity_error("event_date_unavailable", "venue_dates_required")
        end

        requested_dates = (line.event_date_ids + line.venue_event_date_ids).uniq
        return if requested_dates.empty?

        event_dates = if event_dates_by_id
          requested_dates.filter_map do |id|
            date = event_dates_by_id[id]
            date.id.to_s if date&.event_id.to_s == line.product.event_id.to_s
          end
        elsif event_date_rows
          Array(event_date_rows).filter_map do |date|
            date.id.to_s if date.event_id.to_s == line.product.event_id.to_s && requested_dates.include?(date.id.to_s)
          end
        else
          Events::EventDate.where(event_id: line.product.event_id, id: requested_dates)
            .pluck(:id).map(&:to_s)
        end
        missing = requested_dates - event_dates
        return if missing.empty?

        raise_capacity_error(
          "event_date_unavailable",
          "event_dates_event_mismatch",
          dates: missing.join(", ")
        )
      end
      private_class_method :validate_line!

      def self.validate_plan!(plan)
        return if plan.is_a?(Plan) && plan.line.is_a?(Line)

        raise_capacity_error("invalid_capacity_request", "package_quantity_positive")
      end
      private_class_method :validate_plan!

      def self.inventory_ids_for!(line, global, dated)
        requested_ids = line.event_date_ids
        dated_ids = dated.map { |inventory| inventory.event_date_id.to_s }
        missing_date_ids = requested_ids - dated_ids

        case line.product.inventory_mode
        when "unlimited" then []
        when "event_wide"
          global ? [ global.id ] : missing_inventory!
        when "per_date"
          requested_ids.present? && missing_date_ids.empty? ? dated.map(&:id) : missing_inventory!
        when "event_wide_and_per_date"
          if global && requested_ids.present? && missing_date_ids.empty?
            [ global.id, *dated.map(&:id) ]
          else
            missing_inventory!
          end
        else
          raise_capacity_error(
            "inventory_mode_unsupported",
            "unsupported_inventory_mode",
            mode: line.product.inventory_mode
          )
        end
      end
      private_class_method :inventory_ids_for!

      def self.product_capacity_exceeded?(plan, inventories, demand)
        plan.inventory_ids.any? do |id|
          inventory = inventories[id]
          missing_inventory! unless inventory

          inventory.held_count + inventory.sold_count + (demand[id] || 0) + plan.line.package_quantity >
            inventory.capacity
        end
      end
      private_class_method :product_capacity_exceeded?

      def self.venue_capacity_exceeded?(plan, event_dates, demand)
        plan.line.venue_event_date_ids.any? do |id|
          event_date = event_dates[id]
          raise_capacity_error("event_date_unavailable", "event_date_unavailable") unless event_date

          event_date.venue_capacity.present? &&
            event_date.held_venue_count + event_date.issued_venue_count + (demand[id] || 0) + venue_quantity(plan.line) >
              event_date.venue_capacity
        end
      end
      private_class_method :venue_capacity_exceeded?

      def self.missing_inventory!
        raise_capacity_error("inventory_not_configured", "no_inventory_for_requested_dates")
      end
      private_class_method :missing_inventory!

      def self.invalid_violation!
        raise Core::BusinessError.new(
          I18n.t("catalog.inventory.errors.capacity_validation_failed"),
          code: "inventory_validation_failed",
          status: :unprocessable_entity
        )
      end
      private_class_method :invalid_violation!

      def self.raise_capacity_error(code, key, **options)
        raise Core::BusinessError.new(
          I18n.t("catalog.inventory.errors.#{key}", **options),
          code:,
          status: :unprocessable_entity
        )
      end
      private_class_method :raise_capacity_error
    end
  end
end
