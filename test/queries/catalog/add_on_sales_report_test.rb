# frozen_string_literal: true

require "test_helper"

module Catalog
  class AddOnSalesReportTest < ActiveSupport::TestCase
    include CatalogAddOnReportTestHelpers

    setup { setup_add_on_report_data }

    test "aggregates immutable add-on sales and successful refunds by product and currencies" do
      result = AddOnSalesReport.call(event: @event)

      assert_predicate result, :success?, result.error&.message
      row = result.value.find { |candidate| candidate.product_id == @merchandise.id }
      assert_not_nil row
      assert_equal "merchandise", row.type
      assert_equal "Festival Shirt", row.name
      assert_equal 3, row.quantity
      assert_equal 3_500, row.gross_minor
      assert_equal 700, row.refunded_minor
      assert_equal 2_800, row.net_minor
      assert_equal "ETB", row.currency
      assert_equal "ETB", row.settlement_currency
    end

    test "isolates events and supports an allowlisted product-type filter" do
      result = AddOnSalesReport.call(event: @event, filters: { type: "food" })

      assert_predicate result, :success?, result.error&.message
      assert_equal [ @food.id ], result.value.map(&:product_id)
      refute result.value.any? { |row| row.name == "Other Event Shirt" }
    end

    test "supports exact charge and settlement currency filters" do
      result = AddOnSalesReport.call(
        event: @event,
        filters: { currency: "ETB", settlement_currency: "ETB" }
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 2, result.value.length
      assert result.value.all? { |row| row.currency == "ETB" && row.settlement_currency == "ETB" }
    end

    test "rejects unsupported report filters without interpolating SQL" do
      result = AddOnSalesReport.call(event: @event, filters: { type: "ticket" })

      assert_predicate result, :failure?
      assert_equal "invalid_filter", result.error.code
    end

    test "returns no private ticket, credential, payout, or note fields" do
      row = AddOnSalesReport.call(event: @event).value.first

      assert_equal %i[product_id type name quantity gross_minor refunded_minor net_minor currency settlement_currency], row.members
    end
  end
end
