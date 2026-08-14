# frozen_string_literal: true

require "test_helper"

module Ticketing
  class CancellationsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup { setup_package_workflow }

    test "organizer cancellation delegates to exactly one command" do
      refund = Orders::Refund.new(
        type: "item_refund", amount_minor: 3_000, currency: "ETB", status: "created",
        reason_code: "organizer_ticket_cancellation"
      )
      Ticketing::CancelPaidPackage.expects(:call).with(
        ticket: @ticket, actor: core_users(:core_admin), idempotency_key: "ticket-cancel",
        override_reason: nil
      ).returns(Core::BaseService::Result.success(refund))

      post "/tickets/#{@ticket.id}/cancel",
           headers: owner_headers.merge("Idempotency-Key" => "ticket-cancel"), as: :json

      assert_response :success
      assert_equal "created", response.parsed_body.dig("data", "status")
      assert_not response.parsed_body.dig("data").key?("provider_reference")
    end

    test "organizer cancellation requires an idempotency key" do
      post "/tickets/#{@ticket.id}/cancel", headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end
  end
end
