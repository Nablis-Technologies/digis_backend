# frozen_string_literal: true

module Catalog
  module Inventory
    # Builds validated inventory demand for one ticket or add-on product line.
    class ProductLine
      PHYSICAL_ACCESS_TYPES = AdmissionLine::PHYSICAL_ACCESS_TYPES

      def self.call(product:, package_quantity:, selected_event_date_id: nil, event_date_ids: nil)
        new(product:, package_quantity:, selected_event_date_id:, event_date_ids:).call
      end

      def initialize(product:, package_quantity:, selected_event_date_id:, event_date_ids:)
        @product = product
        @package_quantity = package_quantity
        @selected_event_date_id = selected_event_date_id
        @event_date_ids = normalize_ids(event_date_ids)
      end

      def call
        return unless product&.respond_to?(:ticket?)

        product.ticket? ? ticket_line : add_on_line
      end

      private

      attr_reader :product, :package_quantity, :selected_event_date_id, :event_date_ids

      def ticket_line
        return unless product.ticket_type

        AdmissionLine.call(
          product:,
          selected_event_date_id:,
          package_quantity:,
          admissions_per_unit: product.ticket_type.admissions_per_unit
        )
      end

      def add_on_line
        accesses = relevant_accesses
        inventories = product.inventories.to_a
        allowed_dates = configured_date_ids(accesses, inventories)
        return unless valid_dates?(accesses, inventories, allowed_dates)

        Line.new(
          product:,
          event_date_ids:,
          venue_event_date_ids: physical_date_ids(accesses),
          package_quantity:,
          admissions_per_unit: 1
        )
      end

      def valid_dates?(accesses, inventories, allowed_dates)
        date_required = product.inventory_mode.in?(%w[per_date event_wide_and_per_date]) || accesses.any?
        return false if date_required && event_date_ids.empty?
        return false if (event_date_ids - allowed_dates).any?

        true
      end

      def configured_date_ids(accesses, inventories)
        access_dates = accesses.filter_map(&:event_date_id).map(&:to_s).uniq.sort
        return access_dates if access_dates.present?

        inventories.filter_map(&:event_date_id).map(&:to_s).uniq.sort
      end

      def relevant_accesses
        accesses = product.product_accesses.to_a
        return accesses.select(&:parking?) if product.parking?

        accesses
      end

      def physical_date_ids(accesses)
        accesses.filter_map do |access|
          access.event_date_id.to_s if
            PHYSICAL_ACCESS_TYPES.include?(access.type) && event_date_ids.include?(access.event_date_id.to_s)
        end
      end

      def normalize_ids(ids)
        Array(ids).compact.map(&:to_s).uniq.sort
      end
    end
  end
end
