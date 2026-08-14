# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ResaleListingsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Marketplace::ResaleReservationTestHelpers

    setup { setup_resale_reservation_context }

    test "the ticket resale command delegates to one activation service" do
      Marketplace::ActivateListing.expects(:call).with(
        ticket: @ticket,
        actor: @owner,
        asking_amount_minor: 2_400,
        idempotency_key: "api-listing"
      ).returns(Core::BaseService::Result.success(@listing))

      post "/tickets/#{@ticket.id}/resale",
           params: { resale_listing: { asking_amount_minor: 2_400 } },
           headers: headers_for(@owner).merge("Idempotency-Key" => "api-listing"), as: :json

      assert_response :created
      assert_equal @listing.id, response.parsed_body.dig("data", "id")
    end

    test "a buyer sees asking price and fee terms but not seller acquisition economics" do
      get "/resale_listings/#{@listing.id}", headers: headers_for(@second_buyer), as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert_equal @listing.asking_amount_minor, data.fetch("asking_amount_minor")
      assert data.key?("fee_terms")
      %w[seller_acquisition_product_value_minor calculated_cap_minor commercial_fee_component_id
         commercial_fee_schedule_version_id].each do |field|
        assert_not data.key?(field), "buyer response leaked #{field}"
      end
    end

    test "the seller sees the immutable economics captured for their listing" do
      get "/resale_listings/#{@listing.id}", headers: headers_for(@owner), as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert_equal @listing.seller_acquisition_product_value_minor, data.fetch("seller_acquisition_product_value_minor")
      assert_equal @listing.calculated_cap_minor, data.fetch("calculated_cap_minor")
      assert_equal @listing.commercial_fee_component_id, data.fetch("commercial_fee_component_id")
    end

    test "a seller can cancel an open listing through one cancellation service" do
      Marketplace::CancelListing.expects(:call).with(
        listing: @listing,
        idempotency_key: "api-cancel",
        reason: "seller_requested"
      ).returns(Core::BaseService::Result.success(@listing))

      post "/resale_listings/#{@listing.id}/cancel",
           headers: headers_for(@owner).merge("Idempotency-Key" => "api-cancel"), as: :json

      assert_response :success
      assert_equal @listing.id, response.parsed_body.dig("data", "id")
    end

    test "an unrelated attendee cannot create a listing for another owner's ticket" do
      post "/tickets/#{@ticket.id}/resale",
           params: { resale_listing: { asking_amount_minor: 2_400 } },
           headers: headers_for(@other_user).merge("Idempotency-Key" => "api-forbidden"), as: :json

      assert_response :forbidden
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
