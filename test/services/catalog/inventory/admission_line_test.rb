# frozen_string_literal: true

require "test_helper"

module Catalog
  module Inventory
    class AdmissionLineTest < ActiveSupport::TestCase
      Access = Struct.new(:event_date_id, :type)
      TicketType = Struct.new(:date_selection)
      Product = Struct.new(:id, :product_accesses, :ticket_type, :min_per_order) do
        def ticket? = true
      end

      test "fixed hybrid admission covers every access date but reserves physical dates only" do
        venue_id = "019e5f69-dfff-7000-8000-000000000001"
        stream_id = "019e5f69-dfff-7000-8000-000000000002"
        parking_id = "019e5f69-dfff-7000-8000-000000000003"
        product = Product.new(
          "product-1",
          [ Access.new(venue_id, "venue"), Access.new(stream_id, "stream"), Access.new(parking_id, "parking") ],
          TicketType.new("fixed"),
          1
        )

        line = AdmissionLine.call(
          product:, selected_event_date_id: nil, package_quantity: 2, admissions_per_unit: 3
        )

        assert_equal [ venue_id, stream_id, parking_id ], line.event_date_ids
        assert_equal [ venue_id, parking_id ], line.venue_event_date_ids
        assert_equal 2, line.package_quantity
        assert_equal 3, line.admissions_per_unit
      end

      test "choose-one stream access has inventory and date eligibility without venue demand" do
        stream_id = "019e5f69-dfff-7000-8000-000000000002"
        product = Product.new(
          "product-1", [ Access.new(stream_id, "stream") ], TicketType.new("choose_one"), 1
        )

        line = AdmissionLine.call(
          product:, selected_event_date_id: stream_id, package_quantity: 1, admissions_per_unit: 1
        )

        assert_equal [ stream_id ], line.event_date_ids
        assert_empty line.venue_event_date_ids
      end
    end
  end
end
