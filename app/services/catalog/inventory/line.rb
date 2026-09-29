# frozen_string_literal: true

module Catalog
  module Inventory
    # Immutable, lifecycle-neutral ticket demand shared by capacity checks and
    # reservation writes.
    Line = Data.define(
      :product, :event_date_ids, :venue_event_date_ids, :package_quantity, :admissions_per_unit
    ) do
      def initialize(product:, event_date_ids:, venue_event_date_ids: event_date_ids,
        package_quantity:, admissions_per_unit:)
        super(
          product:,
          event_date_ids: normalize_ids(event_date_ids),
          venue_event_date_ids: normalize_ids(venue_event_date_ids),
          package_quantity:,
          admissions_per_unit:
        )
      end

      private

      def normalize_ids(ids)
        Array(ids).compact.map(&:to_s).uniq.sort.freeze
      end
    end
  end
end
