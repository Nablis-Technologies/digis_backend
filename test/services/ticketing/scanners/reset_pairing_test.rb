# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class ResetPairingTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @invitation, @staff_assignment, @device_assignment, @session = paired_invitation
      end

      test "defines the paired-session reset command" do
        assert Scanners.const_defined?(:ResetPairing, false)
      end

      test "revokes the old session and device assignment but preserves the event role" do
        old_token_digest = @session.token_digest
        old_code_digest = @invitation.pairing_code_digest

        result = reset(key: "reset-pairing")

        assert result.success?, result.error&.message
        @invitation.reload
        assert_equal "pairing_reset", @invitation.status
        assert_nil @invitation.paired_at
        assert_equal @staff_assignment.id, @invitation.event_staff_assignment_id
        assert_equal "active", @staff_assignment.reload.status
        assert_equal "revoked", @device_assignment.reload.status
        assert @session.reload.revoked_at.present?
        refute_equal old_token_digest, @invitation.token_digest
        refute_equal old_code_digest, @invitation.pairing_code_digest
        assert_equal 2, @invitation.delivery_revision
        assert_predicate @invitation, :pairable_at?
      end

      test "replays reset without rotating again or enqueuing another delivery" do
        results = []
        operation = -> { results << reset(key: "reset-pairing-replay") }
        counter = -> { Core::OutboxEvent.where(
          event_type: "ticketing.scanner_invitation.delivery_requested",
          aggregate_id: @invitation.id
        ).count }

        assert_idempotent(operation, counter:)
        replay = results.last
        assert replay.success?, replay.error&.message
        assert replay.value.replayed?
        assert_nil replay.value.token
        assert_nil replay.value.pairing_code
        assert_equal 2, @invitation.reload.delivery_revision
      end

      test "re-pairs on a replacement installation with the same event staff assignment" do
        reset_result = reset(key: "reset-and-repair")
        assert reset_result.success?, reset_result.error&.message

        paired = PairInvitation.call(
          pairing_token: reset_result.value.token,
          pairing_method: "organizer_qr",
          installation_id: "replacement-install-#{SecureRandom.hex(6)}",
          device_name: "Replacement gate phone",
          ip_address: "203.0.113.44",
          idempotency_key: "replacement-pair-#{SecureRandom.hex(6)}"
        )

        assert paired.success?, paired.error&.message
        assert_equal "paired", @invitation.reload.status
        assert_equal @staff_assignment.id, @invitation.event_staff_assignment_id
        assert_equal "active", @staff_assignment.reload.status
        assert_equal "revoked", @device_assignment.reload.status
        assert @session.reload.revoked_at.present?
        assert_equal @staff_assignment.id, paired.value.session.scanner_device_assignment.event_staff_assignment_id
        refute_equal @device_assignment.id, paired.value.session.scanner_device_assignment_id
        assert_equal 2, ScannerSession.where(scanner_invitation: @invitation).count
      end

      private

      def reset(key:)
        ResetPairing.call(invitation: @invitation, actor: @actor, idempotency_key: key)
      end

      def paired_invitation
        phone = "+251911234579"
        operator = Core::User.create!(
          email: "paired-scanner-#{SecureRandom.hex(5)}@example.com",
          phone:
        )
        staff_assignment = Events::EventStaffAssignment.create!(
          event: @event,
          organization: @event.organization,
          user: operator,
          role: "scanner",
          status: "active"
        )
        device = ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "paired-scanner-#{SecureRandom.hex(6)}"
        )
        device_assignment = ScannerDeviceAssignment.create!(
          scanner_device: device,
          event: @event,
          event_staff_assignment: staff_assignment,
          assigned_by: @actor,
          starts_at: Time.current,
          ends_at: 3.days.from_now
        )
        created = CreateInvitation.call(
          event: @event,
          actor: @actor,
          phone:,
          starts_at: Time.current,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: "paired-invite-#{SecureRandom.hex(5)}"
        )
        raise created.error unless created.success?

        invitation = created.value.record
        invitation.update!(
          status: "paired",
          paired_user: operator,
          event_staff_assignment: staff_assignment,
          scanner_device: device,
          scanner_device_assignment: device_assignment,
          pairing_method: "sms_link",
          paired_at: Time.current
        )
        session = ScannerSession.create!(
          scanner_invitation: invitation,
          scanner_device_assignment: device_assignment,
          token_digest: ScannerSession.token_digest_for(token: SecureRandom.hex(32)),
          idempotency_key_digest: SecureRandom.hex(32),
          request_digest: SecureRandom.hex(32),
          expires_at: 2.days.from_now
        )
        [ invitation, staff_assignment, device_assignment, session ]
      end
    end
  end
end
