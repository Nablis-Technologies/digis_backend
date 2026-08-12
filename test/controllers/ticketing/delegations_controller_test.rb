# frozen_string_literal: true

require "test_helper"

module Ticketing
  class DelegationsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup { setup_package_workflow }

    test "delegates a ticket with the required idempotency key" do
      post "/tickets/#{@ticket.id}/delegation",
           params: { assignments: { "1" => @recipient.id, "2" => nil, "3" => nil } },
           headers: headers_for(@owner).merge("Idempotency-Key" => "controller-delegate"),
           as: :json

      assert_response :created
      assert_equal true, response.parsed_body["success"]
      assert_equal "delegated", @ticket.reload.credential_mode
    end

    test "requires the idempotency header before mutation" do
      post "/tickets/#{@ticket.id}/delegation",
           params: { assignments: { "1" => @recipient.id, "2" => nil, "3" => nil } },
           headers: headers_for(@owner),
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
      assert_equal "group", @ticket.reload.credential_mode
    end

    test "does not allow an unrelated attendee to delegate" do
      post "/tickets/#{@ticket.id}/delegation",
           params: { assignments: { "1" => @recipient.id, "2" => nil, "3" => nil } },
           headers: headers_for(@other_user).merge("Idempotency-Key" => "controller-unauthorized"),
           as: :json

      assert_response :forbidden
      assert_equal "group", @ticket.reload.credential_mode
    end

    private

    def headers_for(user)
      {
        "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}"
      }
    end
  end
end
