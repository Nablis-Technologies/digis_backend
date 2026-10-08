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
        @pairing = pair_scanner(event: @event, actor: @manager, operator: @operator)
        @assignment = @pairing.session.scanner_device_assignment
        @device = @assignment.scanner_device
        @event_date = @product.product_accesses.first.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      end

      test "records an online admission for an authenticated scanner" do
        process :post, "/scanner/events/#{@event.id}/verifications",
          params: {
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
        { "Authorization" => "Bearer #{@pairing.scanner_session_token}" }
      end
    end
  end
end
