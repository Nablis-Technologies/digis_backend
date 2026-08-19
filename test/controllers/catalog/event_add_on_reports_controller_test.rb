# frozen_string_literal: true

require "test_helper"

module Catalog
  class EventAddOnReportsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include CatalogAddOnReportTestHelpers

    setup { setup_add_on_report_data }

    test "organizer admin receives product and refund aggregates without private fields" do
      get "/events/#{@event.id}/add_on_reports", headers: admin_headers, as: :json

      assert_response :success
      row = response.parsed_body.fetch("data").find { |candidate| candidate["product_id"] == @merchandise.id }
      assert_equal 3_500, row.fetch("gross_minor")
      assert_equal 700, row.fetch("refunded_minor")
      assert_equal 2_800, row.fetch("net_minor")
      refute_includes row.keys, "qr_token"
      refute_includes row.keys, "lookup_code"
      refute_includes row.keys, "payout"
      refute_includes row.keys, "note"
    end

    test "active event managers can read reports but staff and attendees cannot" do
      manager = core_users(:attendee)
      assignment = Events::EventStaffAssignment.create!(
        event: @event,
        user: manager,
        organization: @event.organization,
        role: "manager",
        status: "active"
      )

      get "/events/#{@event.id}/add_on_reports", headers: user_headers, as: :json
      assert_response :success

      assignment.update!(role: "staff")
      get "/events/#{@event.id}/add_on_reports", headers: user_headers, as: :json
      assert_response :forbidden

      assignment.update!(user: core_users(:support), role: "scanner")
      get "/events/#{@event.id}/add_on_reports", headers: admin_headers, as: :json
      assert_response :success
    end

    test "rejects an unsupported product type filter" do
      get "/events/#{@event.id}/add_on_reports?type=ticket", headers: admin_headers, as: :json

      assert_response :unprocessable_entity
      assert_equal "invalid_filter", response.parsed_body.fetch("code")
    end

    test "requires authentication" do
      get "/events/#{@event.id}/add_on_reports", as: :json

      assert_response :unauthorized
    end
  end
end
