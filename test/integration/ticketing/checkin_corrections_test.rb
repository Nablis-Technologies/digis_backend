# frozen_string_literal: true

require "test_helper"

module Ticketing
  class CheckinCorrectionsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @product_access = @product.product_accesses.first
      @event_date = @product_access.event_date
      @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      @product.ticket_type.update!(entry_validation_mode: "qr_and_id")
      @assignment = create_assignment
      @mismatch = record_mismatch
    end

    test "authorized manager can override an identity mismatch and reverse its uses" do
      post "/checkin_logs/#{@mismatch.id}/identity_override",
        params: { identity_override: { reason_code: "operator_error" } },
        headers: admin_headers.merge("Idempotency-Key" => "api-identity-override-1"),
        as: :json

      assert_response :created
      override_id = response.parsed_body.fetch("data").fetch("id")
      assert_equal "success", response.parsed_body.fetch("data").fetch("result")

      post "/checkin_logs/#{override_id}/admission_use_reversal",
        params: {
          admission_use_reversal: {
            reason_code: "operator_error",
            note: "Corrected at the event desk"
          }
        },
        headers: admin_headers.merge("Idempotency-Key" => "api-admission-reversal-1"),
        as: :json

      assert_response :created
      body = response.parsed_body
      assert_equal true, body.fetch("success")
      assert_equal 1, body.fetch("data").fetch("reversals").length
      assert_equal 1, @event.reload.admission_use_reversal_version
    end

    test "identity override requires an idempotency key" do
      post "/checkin_logs/#{@mismatch.id}/identity_override",
        params: { identity_override: { reason_code: "operator_error" } },
        headers: admin_headers,
        as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "unauthorized user cannot override an identity mismatch" do
      post "/checkin_logs/#{@mismatch.id}/identity_override",
        params: { identity_override: { reason_code: "operator_error" } },
        headers: user_headers.merge("Idempotency-Key" => "api-identity-override-forbidden"),
        as: :json

      assert_response :forbidden
      assert_equal "identity_override_forbidden", response.parsed_body.fetch("code")
    end

    private

    def create_assignment
      device = ScannerDevice.create!(
        organization: @event.organization,
        device_identifier: "correction-api-scanner-#{SecureRandom.hex(4)}",
        token_digest: ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
      )
      ScannerDeviceAssignment.create!(scanner_device: device, event: @event, assigned_by: @manager)
    end

    def record_mismatch
      credential = @ticket.current_credential_generation.credentials.first
      claims = Ticketing::Qr::Verifier.call(token: credential.qr_token).value
      result = Ticketing::Admissions::Consume.call(
        claims:,
        product_access: @product_access,
        assignment: @assignment,
        client_scan_id: SecureRandom.uuid,
        scanned_at: @event_date.starts_at + 1.minute,
        lookup_via: "qr",
        identity_check: "mismatch",
        identity_checked_by: @manager,
        now: @event_date.starts_at + 1.minute
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end
  end
end
