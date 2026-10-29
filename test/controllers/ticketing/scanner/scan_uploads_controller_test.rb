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
        @pairing = pair_scanner(event: @event, actor: @manager, operator: @other_user)
        @assignment = @pairing.session.scanner_device_assignment
        @device = @assignment.scanner_device
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
        { "Authorization" => "Bearer #{@pairing.scanner_session_token}" }
      end

      def upload_path
        "/scanner/events/#{@event.id}/scan_uploads"
      end
    end
  end
end
