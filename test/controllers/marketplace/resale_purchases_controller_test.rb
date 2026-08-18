# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ResalePurchasesControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Marketplace::ResaleReservationTestHelpers

    setup { setup_resale_reservation_context }

    test "a buyer delegates reservation to one command and returns an order" do
      order = Orders::Order.new(id: SecureRandom.uuid)
      Marketplace::ReserveListing.expects(:call).with(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "api-purchase",
        answers: [],
        consents: []
      ).returns(Core::BaseService::Result.success(order))

      post "/resale_listings/#{@listing.id}/purchase",
           params: { purchase: {} },
           headers: headers_for(@buyer).merge("Idempotency-Key" => "api-purchase"), as: :json

      assert_response :created
      assert response.parsed_body.dig("data", "id").present?
    end

    test "purchase requires an idempotency key before the reservation command" do
      post "/resale_listings/#{@listing.id}/purchase",
           params: { purchase: {} }, headers: headers_for(@buyer), as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "the seller cannot purchase the seller's own listing" do
      post "/resale_listings/#{@listing.id}/purchase",
           params: { purchase: {} },
           headers: headers_for(@owner).merge("Idempotency-Key" => "seller-purchase"), as: :json

      assert_response :forbidden
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
