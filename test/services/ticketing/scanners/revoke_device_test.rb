# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class RevokeDeviceTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @pairing = pair_scanner(event: @event, actor: @manager, operator: @other_user)
        @device = @pairing.session.scanner_device_assignment.scanner_device
        @assignment = @pairing.session.scanner_device_assignment
        @session = @pairing.session
      end

      test "revokes the device, assignments, and all bound sessions atomically" do
        result = revoke(key: "device-revoke")

        assert result.success?, result.error&.message
        assert_equal "revoked", @device.reload.status
        assert @device.revoked_at.present?
        assert_equal "revoked", @assignment.reload.status
        assert @session.reload.revoked_at.present?
        assert Core::AuditLog.exists?(auditable: @device, action: "ticketing.scanner_device.revoked")
        assert Core::AuditLog.exists?(auditable: @assignment, action: "ticketing.scanner_device_assignment.revoked")
      end

      test "replays device revocation without another audit transition" do
        operation = -> { revoke(key: "device-revoke-replay") }

        assert_audit_idempotent(
          operation,
          action: "ticketing.scanner_device.revoked",
          auditable_type: "Ticketing::ScannerDevice",
          auditable_id: @device.id
        )
        assert_equal "revoked", @device.reload.status
        assert @session.reload.revoked_at.present?
      end

      test "requires an authorized organizer and a reason" do
        forbidden = RevokeDevice.call(
          device: @device,
          actor: @owner,
          reason: "lost",
          idempotency_key: "device-revoke-forbidden"
        )
        missing_reason = RevokeDevice.call(
          device: @device,
          actor: @manager,
          reason: " ",
          idempotency_key: "device-revoke-no-reason"
        )

        assert_equal "device_revoke_forbidden", forbidden.error.code
        assert_equal "revoke_reason_required", missing_reason.error.code
      end

      test "rejects reusing a revocation key with a different reason" do
        first = revoke(key: "device-revoke-conflict", reason: "lost device")
        second = revoke(key: "device-revoke-conflict", reason: "suspected compromise")

        assert first.success?
        assert_equal "idempotency_conflict", second.error.code
      end

      private

      def revoke(key:, reason: "lost device")
        RevokeDevice.call(device: @device, actor: @manager, reason:, idempotency_key: key)
      end
    end
  end
end
