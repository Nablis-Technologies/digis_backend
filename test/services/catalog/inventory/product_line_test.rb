# frozen_string_literal: true

require "test_helper"

module Catalog
  module Inventory
    class ProductLineTest < ActiveSupport::TestCase
      Access = Struct.new(:event_date_id, :type) do
        def parking? = type == "parking"
      end
      Inventory = Struct.new(:event_date_id)
      TicketType = Struct.new(:date_selection, :admissions_per_unit)
      Product = Struct.new(:id, :event_id, :type, :inventory_mode, :product_accesses, :inventories, :ticket_type) do
        def ticket? = type == "ticket"
        def parking? = type == "parking"
      end

      DATE_ONE = "019e5f69-dfff-7000-8000-000000000001"
      DATE_TWO = "019e5f69-dfff-7000-8000-000000000002"

      test "builds an event-wide product line without dates" do
        product = add_on(type: "merchandise", inventory_mode: "event_wide")

        line = build_product_line(product:, package_quantity: 2)

        assert_equal product, line.product
        assert_empty line.event_date_ids
        assert_empty line.venue_event_date_ids
        assert_equal 2, line.package_quantity
        assert_equal 1, line.admissions_per_unit
      end

      test "requires configured dates for per-date inventory" do
        product = add_on(
          type: "food",
          inventory_mode: "per_date",
          inventories: [ Inventory.new(DATE_ONE) ]
        )

        line = build_product_line(product:, package_quantity: 1, event_date_ids: [ DATE_ONE ])
        missing = build_product_line(product:, package_quantity: 1)
        unconfigured = build_product_line(product:, package_quantity: 1, event_date_ids: [ DATE_TWO ])

        assert_equal [ DATE_ONE ], line.event_date_ids
        assert_nil missing
        assert_nil unconfigured
      end

      test "builds parking physical demand from selected parking access dates" do
        product = add_on(
          type: "parking",
          inventory_mode: "per_date",
          inventories: [ Inventory.new(DATE_ONE), Inventory.new(DATE_TWO) ],
          accesses: [ Access.new(DATE_ONE, "parking"), Access.new(DATE_TWO, "parking") ]
        )

        line = build_product_line(
          product:,
          package_quantity: 2,
          event_date_ids: [ DATE_ONE, DATE_TWO ]
        )

        assert_equal [ DATE_ONE, DATE_TWO ], line.event_date_ids
        assert_equal [ DATE_ONE, DATE_TWO ], line.venue_event_date_ids
        assert_equal 2, line.package_quantity
        assert_equal 1, line.admissions_per_unit
      end

      test "rejects dates that do not belong to the add-on" do
        product = add_on(
          type: "parking",
          inventory_mode: "per_date",
          inventories: [ Inventory.new(DATE_ONE), Inventory.new(DATE_TWO) ],
          accesses: [ Access.new(DATE_ONE, "parking") ]
        )

        line = build_product_line(product:, package_quantity: 1, event_date_ids: [ DATE_TWO ])

        assert_nil line
      end

      private

      def build_product_line(**attributes)
        unless defined?(Catalog::Inventory::ProductLine)
          flunk "Catalog::Inventory::ProductLine is missing"
        end

        Catalog::Inventory::ProductLine.call(**attributes)
      end

      def add_on(type:, inventory_mode:, inventories: [], accesses: [])
        Product.new("product-1", "event-1", type, inventory_mode, accesses, inventories, nil)
      end
    end
  end
end
