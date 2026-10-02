# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerReportsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Marketplace::SellerPayoutTestHelpers

    setup do
      setup_seller_payout_context
      create_seller_ledger_entry(amount_minor: 10_000)
      create_seller_ledger_entry(amount_minor: -1_500, type: "adjustment")
    end

    test "seller balance is derived from immutable ledger facts" do
      get "/marketplace/seller/balance", headers: headers_for(@seller), as: :json

      assert_response :success
      assert_equal [ {
        "currency" => "ETB", "ledger_total_minor" => 8_500,
        "reserved_minor" => 0, "available_minor" => 8_500
      } ], response.parsed_body.fetch("data")
    end

    test "seller balance aggregates events but excludes not-yet-available ledger facts" do
      other_event = events_events(:draft_concert)
      create_seller_ledger_entry(
        amount_minor: 3_000, available_at: 1.day.from_now, created_at: Time.current
      )
      create_seller_ledger_entry(amount_minor: 2_000, event: other_event)

      get "/marketplace/seller/balance", headers: headers_for(@seller), as: :json

      assert_response :success
      assert_equal [ {
        "currency" => "ETB", "ledger_total_minor" => 13_500,
        "reserved_minor" => 0, "available_minor" => 10_500
      } ], response.parsed_body.fetch("data")
    end

    test "seller history contains own economics without idempotency material" do
      get "/marketplace/seller/history", headers: headers_for(@seller), as: :json

      assert_response :success
      assert_equal 2, response.parsed_body.fetch("data").length
      response.parsed_body.fetch("data").each do |entry|
        assert_not entry.key?("idempotency_key")
      end
      assert_equal @event.title, response.parsed_body.fetch("data").first.dig("event", "title")
    end

    test "seller history is bounded and includes pagination metadata" do
      get "/marketplace/seller/history?page=2&per_page=1", headers: headers_for(@seller), as: :json

      assert_response :success
      assert_equal 1, response.parsed_body.fetch("data").length
      pagination = response.parsed_body.fetch("pagination")
      assert_equal 2, pagination.fetch("total_count")
      assert_equal 2, pagination.fetch("current_page")
      assert_equal 2, pagination.fetch("total_pages")
    end

    test "seller history honors requested ordering" do
      get "/marketplace/seller/history?order_by=amount_minor&order_direction=desc",
          headers: headers_for(@seller), as: :json

      assert_response :success
      assert_equal [ 10_000, -1_500 ], response.parsed_body.fetch("data").pluck("amount_minor")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
