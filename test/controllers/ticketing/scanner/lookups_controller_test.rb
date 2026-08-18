# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanner
    class LookupsControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @operator = @manager
        @raw_token = SecureRandom.hex(32)
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "lookup-controller-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: @raw_token)
        )
        @assignment = Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          assigned_by: @manager
        )
        @event_date = @product.product_accesses.first.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      end

      test "records a PNR lookup admission through the scanner endpoint" do
        process :post, "/scanner/events/#{@event.id}/lookups",
          params: {
            device_identifier: @device.device_identifier,
            lookup: {
              method: "code",
              query: @ticket.current_credential_generation.credentials.first.lookup_code,
              product_access_id: @product.product_accesses.first.id,
              client_scan_id: SecureRandom.uuid,
              scanned_at: (@event_date.starts_at + 1.minute).iso8601,
              reason_code: "no_qr_printout"
            }
          },
          headers: scanner_headers

        assert_equal 200, response.status, response.body
        assert_equal true, response.parsed_body["success"]
        assert_equal "success", response.parsed_body.dig("data", "status"), response.body
        assert_equal "success", response.parsed_body.dig("data", "checkin", "result"), response.body
      end

      test "requires a reason code for manual lookup" do
        process :post, "/scanner/events/#{@event.id}/lookups",
          params: {
            device_identifier: @device.device_identifier,
            lookup: {
              method: "code",
              query: @ticket.current_credential_generation.credentials.first.lookup_code,
              product_access_id: @product.product_accesses.first.id,
              client_scan_id: SecureRandom.uuid,
              scanned_at: (@event_date.starts_at + 1.minute).iso8601
            }
          },
          headers: scanner_headers

        assert_equal 422, response.status, response.body
        assert_equal "reason_code_required", response.parsed_body.fetch("code"), response.body
      end

      test "allows an authorized online search without admission fields" do
        process :post, "/scanner/events/#{@event.id}/lookups",
          params: {
            device_identifier: @device.device_identifier,
            lookup: {
              method: "online",
              query: @owner.phone,
              reason_code: "no_qr_printout"
            }
          },
          headers: scanner_headers

        assert_equal 200, response.status, response.body
        assert_equal "matches", response.parsed_body.dig("data", "status"), response.body
        assert_equal 1, response.parsed_body.dig("data", "matches").length
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
