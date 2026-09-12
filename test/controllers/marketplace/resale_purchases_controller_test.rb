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

    test "forwards normalized answers and consents to reservation command" do
      order = Orders::Order.new(id: SecureRandom.uuid)
      expected_answers = [
        { question_key: "full_name", value: "Ada Lovelace" }
      ]
      expected_consents = [
        { consent_document_version_id: "doc-v1", acceptance_method: "checkbox" }
      ]

      Marketplace::ReserveListing.expects(:call).with(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "api-purchase-with-answers",
        answers: expected_answers,
        consents: expected_consents
      ).returns(Core::BaseService::Result.success(order))

      post "/resale_listings/#{@listing.id}/purchase",
           params: {
             purchase: {
               answers: [
                 { "question_key" => "full_name", "value" => "Ada Lovelace", "extra_dropped" => "test" }
               ],
               consents: [
                 { "consent_document_version_id" => "doc-v1", "acceptance_method" => "checkbox" }
               ]
             }
           },
           headers: headers_for(@buyer).merge("Idempotency-Key" => "api-purchase-with-answers"), as: :json

      assert_response :created
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

    test "replays a buyer's purchase after the listing is sold" do
      key = "api-purchase-sold-replay"
      first = Marketplace::ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: key
      )
      assert_predicate first, :success?, first.error&.message

      @listing.update_columns(status: "sold", sold_at: Time.current, closed_at: Time.current)

      post "/resale_listings/#{@listing.id}/purchase",
           params: { purchase: {} },
           headers: headers_for(@buyer).merge("Idempotency-Key" => key), as: :json

      assert_response :created
      assert_equal first.value.id, response.parsed_body.dig("data", "id")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
