# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanner
    class DevicesControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @assignment = build_scanner_assignment(
          event: @event,
          assigned_by: @manager,
          device_identifier: "controller-scanner-#{SecureRandom.hex(4)}"
        )
        @device = @assignment.scanner_device
      end

      test "organization administrator can discover safe scanner device fields" do
        get "/organizations/#{@event.organization_id}/scanner_devices", headers: owner_headers, as: :json

        assert_response :success
        device = response.parsed_body.fetch("data").find { |entry| entry["id"] == @device.id }
        assert device
        assert_equal @device.device_identifier, device["device_identifier"]
        refute device.key?("token_digest")
        refute device.key?("idempotency_key_digest")
      end

      test "attendee cannot discover organization scanner devices" do
        get "/organizations/#{@event.organization_id}/scanner_devices", headers: user_headers, as: :json

        assert_response :forbidden
      end

      test "organization administrator can revoke a scanner device" do
        post "/scanner_devices/#{@device.id}/revoke",
             params: { reason: "lost device" },
             headers: owner_headers.merge("Idempotency-Key" => "controller-revoke-device"), as: :json

        assert_response :success
        assert_equal "revoked", @device.reload.status
        assert_equal "revoked", @assignment.reload.status
      end

      test "unauthorized user cannot revoke a scanner device" do
        post "/scanner_devices/#{@device.id}/revoke",
             params: { reason: "lost device" },
             headers: user_headers.merge("Idempotency-Key" => "unauthorized-revoke"), as: :json
        assert_response :forbidden
      end

      test "mutations require an idempotency key" do
        post "/scanner_devices/#{@device.id}/revoke",
             params: { reason: "lost device" }, headers: owner_headers, as: :json
        assert_response :bad_request
        assert_equal "missing_idempotency_key", response.parsed_body["code"]
      end
    end
  end
end
