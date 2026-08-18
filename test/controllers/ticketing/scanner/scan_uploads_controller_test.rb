# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanner
    class ScanUploadsControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 1)
        @event_date = @product.product_accesses.first.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
        @raw_token = SecureRandom.hex(32)
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "upload-limit-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: @raw_token)
        )
        @assignment = Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          assigned_by: @manager
        )
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @other_user,
          organization: @event.organization,
          role: "scanner",
          status: "active"
        )
      end

      test "rejects an upload larger than the bounded scanner batch" do
        scans = Array.new(501) { { client_scan_id: SecureRandom.uuid } }

        process :post, upload_path,
          params: {
            upload: {
              client_upload_id: SecureRandom.uuid,
              cursors: { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 },
              scans:
            }
          }, headers: scanner_headers

        assert_equal 413, response.status, response.body
        assert_equal "scanner_batch_too_large", response.parsed_body["code"]
      end

      private

      def scanner_headers
        {
          "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(@other_user))}",
          "X-Scanner-Token" => @raw_token
        }
      end

      def upload_path
        "/scanner/events/#{@event.id}/scan_uploads?device_identifier=#{@device.device_identifier}"
      end
    end
  end
end
