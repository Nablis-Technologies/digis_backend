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

    test "seller history contains own economics without idempotency material" do
      get "/marketplace/seller/history", headers: headers_for(@seller), as: :json

      assert_response :success
      assert_equal 2, response.parsed_body.fetch("data").length
      response.parsed_body.fetch("data").each do |entry|
        assert_not entry.key?("idempotency_key")
      end
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
