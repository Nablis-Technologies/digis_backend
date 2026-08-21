# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class AuthenticateTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup { setup_package_workflow(admissions_per_unit: 2) }

      test "registers a device with a one-time plaintext token and audits it" do
        result = Ticketing::Scanners::RegisterDevice.call(
          organization: @event.organization,
          actor: @manager,
          device_identifier: "  gate-a-#{SecureRandom.hex(4)} ",
          name: "North gate"
        )

        assert result.success?
        device = result.value.device
        token = result.value.token
        assert_equal "gate-a-#{device.device_identifier.split("-").last}", device.device_identifier
        assert_equal 64, token.length
        assert_equal Ticketing::ScannerDevice.token_digest_for(token:), device.token_digest
        refute_equal token, device.token_digest
        assert Core::AuditLog.exists?(auditable: device, action: "ticketing.scanner_device.registered")
      end

      test "registration requires an active organization owner, admin, or platform administrator" do
        result = Ticketing::Scanners::RegisterDevice.call(
          organization: @event.organization,
          actor: @owner,
          device_identifier: "unauthorized-#{SecureRandom.hex(4)}"
        )

        refute result.success?
        assert_equal "registration_forbidden", result.error.code
      end

      test "assigns a primary organization device to an event" do
        device = register_device(organization: @event.organization, actor: @manager)

        result = Ticketing::Scanners::AssignToEvent.call(
          scanner_device: device,
          event: @event,
          actor: @manager
        )

        assert result.success?
        assert_equal "active", result.value.status
        assert_equal @event.id, result.value.event_id
      end

      test "assigns a collaborator organization device only when the collaboration is active" do
        collaborator = organizations_organizations(:three)
        @event.event_organizations.create!(
          organization: collaborator,
          type: "co_organizer",
          role: "operations",
          status: "active"
        )
        device = register_device(organization: collaborator, actor: core_users(:support))

        result = Ticketing::Scanners::AssignToEvent.call(
          scanner_device: device,
          event: @event,
          actor: @manager
        )

        assert result.success?
        assert_equal device.id, result.value.scanner_device_id
      end

      test "assigns every explicitly requested active zone" do
        event_date = @product.product_accesses.first.event_date
        zones = 2.times.map do |index|
          @event.access_zones.create!(
            event_date:,
            type: "venue",
            name: "Gate #{index + 1}",
            code: "gate-#{index + 1}-#{SecureRandom.hex(3)}",
            active: true,
            sort_order: index + 1
          )
        end
        device = register_device(organization: @event.organization, actor: @manager)

        result = Ticketing::Scanners::AssignToEvent.call(
          scanner_device: device,
          event: @event,
          actor: @manager,
          zone_ids: zones.map(&:id)
        )

        assert result.success?
        assert_equal zones.map(&:id).sort, result.value.access_zones.pluck(:id).sort
      end

      test "rejects a device outside the event organization scope" do
        device = register_device(
          organization: organizations_organizations(:three),
          actor: core_users(:support)
        )

        result = Ticketing::Scanners::AssignToEvent.call(
          scanner_device: device,
          event: @event,
          actor: @manager
        )

        refute result.success?
        assert_equal "device_scope_forbidden", result.error.code
      end

      test "rotates the token and invalidates the old token" do
        old_token = SecureRandom.hex(32)
        device = create_device(raw_token: old_token)

        result = Ticketing::Scanners::RotateToken.call(
          device:, actor: @manager, idempotency_key: "rotate-token-test"
        )

        assert result.success?
        refute_equal old_token, result.value.token
        assert_equal Ticketing::ScannerDevice.token_digest_for(token: result.value.token), device.reload.token_digest
        refute device.token_matches?(old_token)
        assert device.token_matches?(result.value.token)
        assert Core::AuditLog.exists?(auditable: device, action: "ticketing.scanner_device.token_rotated")
      end

      test "replays a token rotation without rotating again or returning plaintext" do
        device = create_device(raw_token: SecureRandom.hex(32))
        key = "rotate-token-replay"
        first = nil
        second = nil

        operation = lambda do
          result = Ticketing::Scanners::RotateToken.call(device:, actor: @manager, idempotency_key: key)
          first ||= result
          second = result if first != result
          result
        end
        assert_audit_idempotent(
          operation,
          action: "ticketing.scanner_device.token_rotated",
          auditable_type: "Ticketing::ScannerDevice",
          auditable_id: device.id
        )

        assert first.success?
        assert second.success?
        assert_equal Ticketing::ScannerDevice.token_digest_for(token: first.value.token), device.reload.token_digest
        assert_nil second.value.token
        assert second.value.replayed?
        assert_equal 1, Core::AuditLog.for_auditable(device)
          .for_action("ticketing.scanner_device.token_rotated").count
      end

      test "rejects reuse of a rotation key for another device" do
        first_device = create_device(raw_token: SecureRandom.hex(32))
        second_device = create_device(raw_token: SecureRandom.hex(32))
        key = "rotate-token-cross-device"

        first = Ticketing::Scanners::RotateToken.call(device: first_device, actor: @manager, idempotency_key: key)
        second = Ticketing::Scanners::RotateToken.call(device: second_device, actor: @manager, idempotency_key: key)

        assert first.success?
        refute second.success?
        assert_equal "idempotency_conflict", second.error.code
      end

      test "revokes a device and all active event assignments" do
        device = create_device(raw_token: SecureRandom.hex(32))
        assignment = create_assignment(device:)

        result = Ticketing::Scanners::RevokeDevice.call(
          device:, actor: @manager, reason: "suspected device compromise", idempotency_key: "revoke-device-test"
        )

        assert result.success?
        assert_equal "revoked", device.reload.status
        assert device.revoked_at.present?
        assert_equal "revoked", assignment.reload.status
        assert Core::AuditLog.exists?(auditable: device, action: "ticketing.scanner_device.revoked")
        assert Core::AuditLog.exists?(auditable: assignment, action: "ticketing.scanner_device_assignment.revoked")
      end

      test "device revocation requires an authorized actor and reason" do
        device = create_device(raw_token: SecureRandom.hex(32))

        forbidden = Ticketing::Scanners::RevokeDevice.call(
          device:, actor: @owner, reason: "suspected device compromise", idempotency_key: "revoke-forbidden"
        )
        missing_reason = Ticketing::Scanners::RevokeDevice.call(
          device:, actor: @manager, reason: " ", idempotency_key: "revoke-missing-reason"
        )

        refute forbidden.success?
        assert_equal "device_revoke_forbidden", forbidden.error.code
        refute missing_reason.success?
        assert_equal "revoke_reason_required", missing_reason.error.code
      end

      test "replays device revocation without creating another audit" do
        device = create_device(raw_token: SecureRandom.hex(32))
        create_assignment(device:)
        key = "revoke-device-replay"
        first = nil
        second = nil

        operation = lambda do
          result = Ticketing::Scanners::RevokeDevice.call(
            device:, actor: @manager, reason: "lost device", idempotency_key: key
          )
          first ||= result
          second = result if first != result
          result
        end
        assert_audit_idempotent(
          operation,
          action: "ticketing.scanner_device.revoked",
          auditable_type: "Ticketing::ScannerDevice",
          auditable_id: device.id
        )

        assert first.success?
        assert second.success?
        assert_equal "revoked", second.value.status
      end

      test "rejects a revocation key reused with a different reason" do
        device = create_device(raw_token: SecureRandom.hex(32))
        key = "revoke-device-reason-conflict"

        first = Ticketing::Scanners::RevokeDevice.call(
          device:, actor: @manager, reason: "lost device", idempotency_key: key
        )
        second = Ticketing::Scanners::RevokeDevice.call(
          device:, actor: @manager, reason: "suspected compromise", idempotency_key: key
        )

        assert first.success?
        refute second.success?
        assert_equal "idempotency_conflict", second.error.code
      end

      test "authenticates an active device and scanner operator for an active assignment" do
        token = SecureRandom.hex(32)
        device = create_device(raw_token: token)
        assignment = create_assignment(device:)
        create_scanner_operator

        result = Ticketing::Scanners::Authenticate.call(
          operator: @scanner_operator,
          device_identifier: device.device_identifier,
          token:,
          event: @event,
          now: Time.current
        )

        assert result.success?
        assert_equal device.id, result.value.device.id
        assert_equal assignment.id, result.value.assignment.id
      end

      test "rejects suspended devices and assignments outside their time window" do
        token = SecureRandom.hex(32)
        device = create_device(raw_token: token)
        assignment = create_assignment(device:, starts_at: 1.hour.from_now)
        create_scanner_operator

        device.update!(status: "suspended")
        suspended_result = authenticate(device:, token:)
        refute suspended_result.success?
        assert_equal "device_inactive", suspended_result.error.code

        device.update!(status: "active")
        assignment.update!(starts_at: 1.hour.from_now)
        window_result = authenticate(device:, token:)
        refute window_result.success?
        assert_equal "assignment_outside_window", window_result.error.code
      end

      test "rejects revoked devices" do
        token = SecureRandom.hex(32)
        device = create_device(raw_token: token)
        create_assignment(device:)
        create_scanner_operator
        device.update!(status: "revoked")

        result = authenticate(device:, token:)

        refute result.success?
        assert_equal "device_inactive", result.error.code
      end

      test "allows an event manager and primary organization administrator" do
        token = SecureRandom.hex(32)
        device = create_device(raw_token: token)
        create_assignment(device:)
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @other_user,
          organization: @event.organization,
          role: "manager",
          status: "active"
        )

        manager_result = authenticate(device:, token:, operator: @other_user)
        admin_result = authenticate(device:, token:, operator: @recipient)

        assert manager_result.success?
        assert admin_result.success?
      end

      test "rejects an operator who has no event scanner role" do
        token = SecureRandom.hex(32)
        device = create_device(raw_token: token)
        create_assignment(device:)

        result = authenticate(device:, token:, operator: @owner)

        refute result.success?
        assert_equal "operator_forbidden", result.error.code
      end

      private

      def register_device(organization:, actor:)
        Ticketing::Scanners::RegisterDevice.call(
          organization:,
          actor:,
          device_identifier: "scanner-#{SecureRandom.hex(4)}"
        ).value.device
      end

      def create_device(raw_token:)
        Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "scanner-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: raw_token)
        )
      end

      def create_assignment(device:, starts_at: nil, ends_at: nil)
        Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: device,
          event: @event,
          assigned_by: @manager,
          starts_at:,
          ends_at:
        )
      end

      def create_scanner_operator
        @scanner_operator = @other_user
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @scanner_operator,
          organization: @event.organization,
          role: "scanner",
          status: "active"
        )
      end

      def authenticate(device:, token:, operator: @scanner_operator)
        Ticketing::Scanners::Authenticate.call(
          operator:,
          device_identifier: device.device_identifier,
          token:,
          event: @event,
          now: Time.current
        )
      end
    end
  end
end
