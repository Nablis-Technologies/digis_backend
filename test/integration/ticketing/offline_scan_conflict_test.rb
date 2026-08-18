# frozen_string_literal: true

require "test_helper"

module Ticketing
  class OfflineScanConflictTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @event_date = @product.product_accesses.first.event_date
      @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      @raw_token = SecureRandom.hex(32)
      @device = Ticketing::ScannerDevice.create!(
        organization: @event.organization,
        device_identifier: "upload-controller-#{SecureRandom.hex(4)}",
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

    test "retries an upload and reconciles competing offline scans" do
      scan = scan_attributes
      params = upload_params(client_upload_id: SecureRandom.uuid, scans: [ scan ])

      process :post, upload_path,
        params: { upload: params }, headers: scanner_headers

      assert_equal 200, response.status, response.body
      first_body = response.parsed_body
      assert_equal "success", first_body.dig("data", "results", 0, "result")

      process :post, upload_path,
        params: { upload: params }, headers: scanner_headers

      assert_equal 200, response.status, response.body
      assert_equal first_body, response.parsed_body
      assert_equal 1, Ticketing::CheckinLog.where(client_scan_id: scan[:client_scan_id]).count
    end

    test "returns an empty heartbeat with synchronization data" do
      process :post, upload_path,
        params: { upload: upload_params(client_upload_id: SecureRandom.uuid, scans: []) },
        headers: scanner_headers

      assert_equal 200, response.status, response.body
      assert_equal [], response.parsed_body.dig("data", "results")
      assert_equal "delta", response.parsed_body.dig("data", "sync", "sync_mode")
    end

    private

    def upload_params(client_upload_id:, scans:)
      {
        client_upload_id:,
        cursors: { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 },
        scans:
      }
    end

    def scan_attributes
      credential = @ticket.current_credential_generation.credentials.first
      {
        credential_id: credential.id,
        ticket_id: @ticket.id,
        credential_version: credential.credential_generation.version,
        product_access_id: @product.product_accesses.first.id,
        client_scan_id: SecureRandom.uuid,
        scanned_at: (@event_date.starts_at + 1.minute).iso8601,
        result: "success",
        lookup_via: "qr",
        identity_check_result: "not_required"
      }
    end

    def scanner_headers
      headers_for(@other_user).merge("X-Scanner-Token" => @raw_token)
    end

    def upload_path
      "/scanner/events/#{@event.id}/scan_uploads?device_identifier=#{@device.device_identifier}"
    end

    def headers_for(user)
      {
        "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}"
      }
    end
  end
end
