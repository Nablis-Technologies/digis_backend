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
        @pairing = pair_scanner(event: @event, actor: @manager, operator: @operator)
        @assignment = @pairing.session.scanner_device_assignment
        @device = @assignment.scanner_device
      end

      test "returns a full snapshot to an authenticated scanner" do
        process :get, "/scanner/events/#{@event.id}/sync",
            params: { mode: "full" },
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
              cursors: { revocations: 0 }.to_json
            },
            headers: scanner_headers

        assert_equal 400, response.status, response.body
        assert_equal "scanner_cursors_required", response.parsed_body["code"]
      end

      private

      def scanner_headers
        { "Authorization" => "Bearer #{@pairing.scanner_session_token}" }
      end
    end
  end
end
