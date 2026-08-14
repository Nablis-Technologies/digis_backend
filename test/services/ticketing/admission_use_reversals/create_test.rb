# frozen_string_literal: true

require "test_helper"

module Ticketing
  module AdmissionUseReversals
    class CreateTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @product_access = @product.product_accesses.first
        @event_date = @product_access.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
        @assignment = create_assignment
        @checkin = consume
      end

      test "reverses every use from a group check-in as one append-only group" do
        result = create_reversal

        assert_predicate result, :success?, result.error&.message
        reversals = result.value.fetch(:reversals)
        assert_equal 2, reversals.length
        assert_equal 1, reversals.map(&:reversal_version).uniq.length
        assert_equal 1, @event.reload.admission_use_reversal_version
        assert_equal 1, reversals.map(&:reversal_group_id).uniq.length
        assert_equal 2, AdmissionUseReversal.where(checkin_log: @checkin).count
        assert_equal [ 1, 1 ], @checkin.reload.admission_uses.order(:admission_slot_id).map(&:usage_number)
        assert Core::AuditLog.exists?(
          action: "ticketing.admission_use.reversal_recorded",
          auditable_id: reversals.first.id
        )
        assert Core::OutboxEvent.exists?(
          event_type: "ticketing.admission_use.reversal_recorded",
          aggregate_id: @event.id
        )
      end

      test "replays the same reversal idempotently and rejects a changed retry" do
        first = create_reversal
        replay = create_reversal
        conflict = create_reversal(reason_code: "wrong_ticket")

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.fetch(:reversal_group_id), replay.value.fetch(:reversal_group_id)
        assert_equal 2, AdmissionUseReversal.where(checkin_log: @checkin).count
        assert_predicate conflict, :failure?
        assert_equal "idempotency_conflict", conflict.error.code
      end

      test "restores active eligibility without reusing a historical usage number" do
        create_reversal

        next_checkin = consume(client_scan_id: SecureRandom.uuid)

        assert_equal "success", next_checkin.result
        assert_equal [ 2, 2 ], next_checkin.admission_uses.order(:admission_slot_id).map(&:usage_number)
      end

      test "rejects a reversal by an unauthorized actor" do
        result = create_reversal(manager: @other_user)

        assert_predicate result, :failure?
        assert_equal "admission_use_reversal_forbidden", result.error.code
        assert_empty AdmissionUseReversal.where(checkin_log: @checkin)
      end

      test "rejects a successful check-in with no admission uses" do
        duplicate = consume(client_scan_id: SecureRandom.uuid)
        result = Ticketing::AdmissionUseReversals::Create.call(
          checkin_log: duplicate,
          manager: @manager,
          reason_code: "operator_error",
          idempotency_key: "empty-reversal"
        )

        assert_equal "duplicate", duplicate.result
        assert_predicate result, :failure?
        assert_equal "admission_use_reversal_not_possible", result.error.code
      end

      private

      def create_assignment
        device = ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "reversal-scanner-#{SecureRandom.hex(4)}",
          token_digest: ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
        )
        ScannerDeviceAssignment.create!(scanner_device: device, event: @event, assigned_by: @manager)
      end

      def consume(client_scan_id: SecureRandom.uuid)
        claims = Ticketing::Qr::Verifier.call(
          token: @ticket.current_credential_generation.credentials.first.qr_token
        ).value
        result = Ticketing::Admissions::Consume.call(
          claims:,
          product_access: @product_access,
          assignment: @assignment,
          client_scan_id:,
          scanned_at: @event_date.starts_at + 1.minute,
          lookup_via: "qr",
          identity_check: nil,
          now: @event_date.starts_at + 1.minute
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def create_reversal(manager: @manager, reason_code: "operator_error")
        Ticketing::AdmissionUseReversals::Create.call(
          checkin_log: @checkin,
          manager:,
          reason_code:,
          idempotency_key: "admission-reversal-1"
        )
      end
    end
  end
end
