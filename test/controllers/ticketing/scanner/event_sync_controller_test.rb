# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanner
    class EventSyncControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @operator = @other_user
        @raw_token = SecureRandom.hex(32)
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "sync-scanner-#{SecureRandom.hex(4)}",
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

      test "returns a full snapshot to an authenticated scanner" do
        process :get, "/scanner/events/#{@event.id}/sync",
            params: { mode: "full", device_identifier: @device.device_identifier },
            headers: scanner_headers

        assert_equal 200, response.status, response.body
        assert_equal true, response.parsed_body["success"]
        assert_equal "full", response.parsed_body.dig("data", "sync_mode")
        assert_equal @event.id.to_s, response.parsed_body.dig("data", "event_id")
      end

      test "returns a delta using explicit cursors" do
        process :get, "/scanner/events/#{@event.id}/sync",
            params: {
              mode: "delta",
              device_identifier: @device.device_identifier,
              cursors: { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 }.to_json
            },
            headers: scanner_headers

        assert_equal 200, response.status, response.body
        assert_equal "delta", response.parsed_body.dig("data", "sync_mode")
      end

      test "rejects a delta without all cursors" do
        process :get, "/scanner/events/#{@event.id}/sync",
            params: {
              mode: "delta",
              device_identifier: @device.device_identifier,
              cursors: { revocations: 0 }.to_json
            },
            headers: scanner_headers

        assert_equal 400, response.status, response.body
        assert_equal "scanner_cursors_required", response.parsed_body["code"]
      end

      private

      def scanner_headers
        headers_for(@operator).merge("X-Scanner-Token" => @raw_token)
      end

      def headers_for(user)
        {
          "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}"
        }
      end
    end
  end
end
