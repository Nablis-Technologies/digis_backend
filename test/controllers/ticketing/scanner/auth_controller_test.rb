# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanner
    class AuthControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @operator = @other_user
        @raw_token = SecureRandom.hex(32)
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "controller-scanner-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: @raw_token)
        )
        @assignment = Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          assigned_by: @manager
        )
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @operator,
          organization: @event.organization,
          role: "scanner",
          status: "active"
        )
      end

      test "authenticates a scanner with operator JWT and scanner token headers" do
        post "/scanner/auth",
             params: { event_id: @event.id, device_identifier: @device.device_identifier },
             headers: headers_for(@operator).merge("X-Scanner-Token" => @raw_token),
             as: :json

        assert_response :success
        assert_equal true, response.parsed_body["success"]
        assert_equal @device.id, response.parsed_body.dig("data", "device_id")
        assert_equal @assignment.id, response.parsed_body.dig("data", "assignment_id")
      end

      test "requires the operator JWT" do
        post "/scanner/auth",
             params: { event_id: @event.id, device_identifier: @device.device_identifier },
             headers: { "X-Scanner-Token" => @raw_token },
             as: :json

        assert_response :unauthorized
        assert_equal "authentication_required", response.parsed_body["code"]
      end

      test "rejects a wrong scanner token" do
        post "/scanner/auth",
             params: { event_id: @event.id, device_identifier: @device.device_identifier },
             headers: headers_for(@operator).merge("X-Scanner-Token" => SecureRandom.hex(32)),
             as: :json

        assert_response :unauthorized
        assert_equal "authentication_failed", response.parsed_body["code"]
      end

      test "rejects an authenticated operator without scanner permission" do
        post "/scanner/auth",
             params: { event_id: @event.id, device_identifier: @device.device_identifier },
             headers: headers_for(@owner).merge("X-Scanner-Token" => @raw_token),
             as: :json

        assert_response :forbidden
        assert_equal "operator_forbidden", response.parsed_body["code"]
      end

      private

      def headers_for(user)
        {
          "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}"
        }
      end
    end
  end
end
