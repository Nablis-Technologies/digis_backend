# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Checkins
    class OverrideIdentityMismatchTest < ActiveSupport::TestCase
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

      test "records an immutable mismatch attempt without an admission use" do
        mismatch = RecordIdentityMismatch.call(
          ticket: @ticket,
          credential: current_credential,
          credential_version: @ticket.credential_version,
          product_access: @product_access,
          event_date: @event_date,
          assignment: @assignment,
          client_scan_id: SecureRandom.uuid,
          scanned_at: @event_date.starts_at + 1.minute,
          lookup_via: "qr",
          identity_checked_by: @manager,
          received_at: Time.current
        )

        assert_predicate mismatch, :success?, mismatch.error&.message
        assert_equal "identity_mismatch", mismatch.value.result
        assert_equal "mismatch", mismatch.value.identity_check_result
        assert_empty mismatch.value.admission_uses
      end

      test "appends a successful linked override after online manager revalidation" do
        result = override

        assert_predicate result, :success?, result.error&.message
        override_log = result.value
        assert_equal "success", override_log.result
        assert_equal "mismatch", override_log.identity_check_result
        assert_equal @mismatch.id, override_log.overrides_checkin_log_id
        assert_equal @manager.id, override_log.identity_override_by_id
        assert_equal "operator_error", override_log.identity_override_reason
        assert_equal 1, override_log.admission_uses.count
        assert_equal override_log.id, @mismatch.reload.identity_override.id
        assert_empty @mismatch.admission_uses
        assert Core::AuditLog.exists?(
          action: "ticketing.checkin.identity_override_recorded",
          auditable_id: override_log.id
        )
        assert Core::OutboxEvent.exists?(
          event_type: "ticketing.checkin.identity_override_recorded",
          aggregate_id: override_log.id
        )
      end

      test "replays the same override idempotently and rejects a changed retry" do
        first = override
        replay = override
        conflict = override(reason_code: "wrong_ticket")

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
        assert_equal 1, CheckinLog.where(overrides_checkin_log_id: @mismatch.id).count
        assert_predicate conflict, :failure?
        assert_equal "idempotency_conflict", conflict.error.code
      end

      test "rejects an override by an unauthorized actor" do
        result = OverrideIdentityMismatch.call(
          checkin_log: @mismatch,
          manager: @other_user,
          reason_code: "operator_error",
          idempotency_key: "unauthorized-override"
        )

        assert_predicate result, :failure?
        assert_equal "identity_override_forbidden", result.error.code
        assert_empty AdmissionUse.where(product_access: @product_access)
      end

      test "rejects an offline identity mismatch override" do
        upload = ScanUpload.create!(
          scanner_device_assignment: @assignment,
          client_upload_id: SecureRandom.uuid,
          received_at: Time.current
        )
        offline_mismatch = RecordAttempt.call(
          ticket: @ticket,
          credential: current_credential,
          credential_version: @ticket.credential_version,
          product_access: @product_access,
          event_date: @event_date,
          assignment: @assignment,
          scan_upload: upload,
          client_scan_id: SecureRandom.uuid,
          result: "identity_mismatch",
          scanned_at: @event_date.starts_at + 1.minute,
          lookup_via: "qr",
          identity_check_result: "mismatch",
          identity_checked_by: @manager,
          received_at: Time.current
        ).value

        result = OverrideIdentityMismatch.call(
          checkin_log: offline_mismatch,
          manager: @manager,
          reason_code: "operator_error",
          idempotency_key: "offline-identity-override"
        )

        assert_predicate result, :failure?
        assert_equal "identity_override_not_possible", result.error.code
        assert_empty CheckinLog.where(overrides_checkin_log_id: offline_mismatch.id)
      end

      test "does not override after credential revalidation fails" do
        current_credential.update!(status: "revoked", revoked_at: Time.current)

        result = override

        assert_predicate result, :failure?
        assert_equal "identity_override_revalidation_failed", result.error.code
        assert_empty AdmissionUse.where(product_access: @product_access)
        assert_empty CheckinLog.where(overrides_checkin_log_id: @mismatch.id)
      end

      private

      def current_credential
        @ticket.reload.current_credential_generation.credentials.first
      end

      def create_assignment
        build_scanner_assignment(
          event: @event,
          assigned_by: @manager,
          device_identifier: "override-scanner-#{SecureRandom.hex(4)}"
        )
      end

      def record_mismatch
        claims = Ticketing::Qr::Verifier.call(token: current_credential.qr_token).value
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

      def override(reason_code: "operator_error")
        OverrideIdentityMismatch.call(
          checkin_log: @mismatch,
          manager: @manager,
          reason_code:,
          idempotency_key: "identity-override-1"
        )
      end
    end
  end
end
