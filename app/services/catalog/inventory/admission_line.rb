# frozen_string_literal: true

module Catalog
  module Inventory
    # Builds one admission's product-inventory and physical-venue demand.
    class AdmissionLine
      PHYSICAL_ACCESS_TYPES = %w[venue parking].freeze

      def self.call(product:, selected_event_date_id:, package_quantity:, admissions_per_unit:)
        new(product:, selected_event_date_id:, package_quantity:, admissions_per_unit:).call
      end

      def initialize(product:, selected_event_date_id:, package_quantity:, admissions_per_unit:)
        @product = product
        @selected_event_date_id = selected_event_date_id&.to_s
        @package_quantity = package_quantity
        @admissions_per_unit = admissions_per_unit
      end

      def call
        accesses = product.product_accesses.to_a
        return unless product.ticket? && product.ticket_type

        dates = if product.ticket_type.date_selection == "choose_one"
          return unless selected_event_date_id.present? && accesses.any? do |access|
            access.event_date_id.to_s == selected_event_date_id
          end

          [ selected_event_date_id ]
        else
          accesses.filter_map(&:event_date_id)
        end
        physical_dates = accesses.filter_map do |access|
          access.event_date_id if PHYSICAL_ACCESS_TYPES.include?(access.type) && dates.include?(access.event_date_id.to_s)
        end

        Line.new(
          product:,
          event_date_ids: dates,
          venue_event_date_ids: physical_dates,
          package_quantity:,
          admissions_per_unit:
        )
      end

      private

      attr_reader :product, :selected_event_date_id, :package_quantity, :admissions_per_unit
    end
  end
end
