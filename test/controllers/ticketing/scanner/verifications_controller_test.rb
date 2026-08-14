# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanner
    class VerificationsControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @operator = @other_user
        @raw_token = SecureRandom.hex(32)
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "verification-scanner-#{SecureRandom.hex(4)}",
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
        @event_date = @product.product_accesses.first.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      end

      test "records an online admission for an authenticated scanner" do
        process :post, "/scanner/events/#{@event.id}/verifications",
          params: {
            device_identifier: @device.device_identifier,
            verification: {
              qr_token: @ticket.current_credential_generation.credentials.first.qr_token,
              product_access_id: @product.product_accesses.first.id,
              client_scan_id: SecureRandom.uuid,
              scanned_at: (@event_date.starts_at + 1.minute).iso8601,
              lookup_via: "qr"
            }
          },
          headers: scanner_headers

        assert_equal 200, response.status, response.body
        assert_equal true, response.parsed_body["success"]
        assert_equal "success", response.parsed_body.dig("data", "result"), response.body
        assert_equal 2, response.parsed_body.dig("data", "admission_use_count")
      end

      private

      def scanner_headers
        {
          "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(@operator))}",
          "X-Scanner-Token" => @raw_token
        }
      end
    end
  end
end
