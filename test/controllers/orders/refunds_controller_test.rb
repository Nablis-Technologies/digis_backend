# frozen_string_literal: true

require "test_helper"

module Orders
  class RefundsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Orders::RefundApiTestHelpers

    setup do
      @refund = create_api_refund
      @other_refund = create_api_refund(buyer: core_users(:support))
    end

    test "buyer can see only safe refund status fields" do
      get "/refunds/#{@refund.id}", headers: user_headers, as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert_equal @refund.id, data.fetch("id")
      assert_equal 1_000, data.fetch("amount_minor")
      assert_equal "ETB", data.fetch("currency")
      assert_equal "succeeded", data.fetch("status")
      assert_equal "event_cancellation", data.fetch("reason_code")
      assert data.key?("created_at")
      assert data.key?("updated_at")
      %w[payment_id provider_reference provider_fee_minor provider_fee_currency pending_reason next_retry_at].each do |key|
        assert_not data.key?(key), "buyer response leaked #{key}"
      end
    end

    test "buyer refund index is scoped to the buyer" do
      get "/refunds", headers: user_headers, as: :json

      assert_response :success
      assert_equal [ @refund.id ], response.parsed_body.fetch("data").pluck("id")
      assert_not_includes response.body, @other_refund.id
    end

    test "unrelated user cannot view a refund" do
      get "/refunds/#{@refund.id}", headers: { "Authorization" => "Bearer #{issue_token(:support)}" }, as: :json

      assert_response :forbidden
    end
  end
end
