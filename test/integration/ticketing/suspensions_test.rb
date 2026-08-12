# frozen_string_literal: true

require "test_helper"

module Ticketing
  class SuspensionsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow
    end

    test "authorized manager opens a suspension and excludes the restricted note" do
      post "/tickets/#{@ticket.id}/suspension",
        params: {
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now.iso8601,
          internal_note: "Restricted identity-review detail"
        },
        headers: admin_headers.merge("Idempotency-Key" => "api-suspension-open"),
        as: :json

      assert_response :created
      body = response.parsed_body
      assert_equal true, body.fetch("success")
      assert_equal "active", body.fetch("data").fetch("status")
      assert_not body.fetch("data").key?("internal_note")
      assert_equal true, @ticket.reload.revocation.is_suspended
    end

    test "missing idempotency key returns bad request" do
      post "/tickets/#{@ticket.id}/suspension",
        params: { reason_code: "suspected_fraud" },
        headers: admin_headers,
        as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end
  end
end
