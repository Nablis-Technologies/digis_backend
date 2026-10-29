# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ScannerSessionTest < ActiveSupport::TestCase
    test "defines the event-scoped scanner session model" do
      assert Ticketing.const_defined?(:ScannerSession, false)
    end

    test "stores only a keyed session-token digest and expires at its finite deadline" do
      @raw_token = SecureRandom.hex(32)
      invitation = scanner_invitation
      assignment = scanner_device_assignment(invitation:)

      session = ScannerSession.create!(
        scanner_invitation: invitation,
        scanner_device_assignment: assignment,
        token_digest: ScannerSession.token_digest_for(token: @raw_token),
        idempotency_key_digest: SecureRandom.hex(32),
        request_digest: SecureRandom.hex(32),
        expires_at: 2.hours.from_now
      )

      stored_digest = ScannerSession.connection.select_value(
        "SELECT token_digest FROM ticketing_scanner_sessions WHERE id = '#{session.id}'"
      )
      assert_equal ScannerSession.token_digest_for(token: @raw_token), stored_digest
      refute_equal @raw_token, stored_digest
      assert session.active_at?(Time.current)
      assert_not session.active_at?(session.expires_at)

      session.update!(revoked_at: Time.current)
      assert_not session.reload.active_at?(Time.current)
    end

    test "does not allow duplicate session token digests" do
      token = SecureRandom.hex(32)
      invitation = scanner_invitation
      assignment = scanner_device_assignment(invitation:)
      digest = ScannerSession.token_digest_for(token:)

      ScannerSession.create!(
        scanner_invitation: invitation,
        scanner_device_assignment: assignment,
        token_digest: digest,
        idempotency_key_digest: SecureRandom.hex(32),
        request_digest: SecureRandom.hex(32),
        expires_at: 2.hours.from_now
      )
      duplicate = ScannerSession.new(
        scanner_invitation: invitation,
        scanner_device_assignment: assignment,
        token_digest: digest,
        idempotency_key_digest: SecureRandom.hex(32),
        request_digest: SecureRandom.hex(32),
        expires_at: 2.hours.from_now
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:token_digest], "has already been taken"
    end

    private

    def scanner_invitation
      event = events_events(:ready_listing)
      token = SecureRandom.hex(32)
      phone = "+251911234568"
      operator = Core::User.create!(
        email: "scanner-session-#{SecureRandom.hex(6)}@example.com",
        phone:
      )
      staff_assignment = Events::EventStaffAssignment.create!(
        event:,
        organization: event.organization,
        user: operator,
        role: "scanner",
        status: "active"
      )
      device = ScannerDevice.create!(
        organization: event.organization,
        device_identifier: "session-test-#{SecureRandom.hex(6)}"
      )
      device_assignment = ScannerDeviceAssignment.create!(
        scanner_device: device,
        event:,
        event_staff_assignment: staff_assignment,
        assigned_by: core_users(:super_admin),
        starts_at: Time.current,
        ends_at: 2.days.from_now
      )
      ScannerInvitation.create!(
        event:,
        organization: event.organization,
        created_by: core_users(:super_admin),
        paired_user: operator,
        event_staff_assignment: staff_assignment,
        scanner_device: device,
        scanner_device_assignment: device_assignment,
        phone:,
        phone_digest: ScannerInvitation.phone_digest_for(event_id: event.id, phone:),
        token:,
        token_digest: ScannerInvitation.token_digest_for(token:),
        pairing_code_digest: ScannerInvitation.pairing_code_digest_for(code: "482911"),
        create_idempotency_key_digest: SecureRandom.hex(32),
        create_request_digest: SecureRandom.hex(32),
        zone_mode: "all_current_zones",
        selected_zone_ids: [],
        status: "paired",
        delivery_status: "delivered",
        delivery_revision: 1,
        starts_at: Time.current,
        ends_at: 3.days.from_now,
        expires_at: 2.days.from_now,
        pairing_code_expires_at: 1.hour.from_now,
        paired_at: Time.current,
        pairing_method: "sms_link"
      )
    end

    def scanner_device_assignment(invitation:)
      invitation.scanner_device_assignment
    end
  end
end
