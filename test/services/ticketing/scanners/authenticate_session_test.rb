# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class AuthenticateSessionTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        invitation_result = CreateInvitation.call(
          event: @event,
          actor: core_users(:core_admin),
          phone: "0911 23 45 79",
          starts_at: 1.hour.ago,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: "session-auth-invite-#{SecureRandom.hex(5)}"
        )
        raise invitation_result.error unless invitation_result.success?

        @invitation = invitation_result.value.record
        pairing_result = PairInvitation.call(
          pairing_token: invitation_result.value.token,
          pairing_method: "sms_link",
          installation_id: "session-auth-install-#{SecureRandom.hex(5)}",
          device_name: "Scanner phone",
          ip_address: "203.0.113.91",
          idempotency_key: "session-auth-pair-#{SecureRandom.hex(5)}"
        )
        raise pairing_result.error unless pairing_result.success?

        @session = pairing_result.value.session
        @token = pairing_result.value.scanner_session_token
        @assignment = @session.scanner_device_assignment
      end

      test "authenticates the scanner bearer and resolves its event operator and device scope" do
        result = AuthenticateSession.call(token: @token, event: @event)

        assert result.success?, result.error&.message
        assert_equal @assignment.id, result.value.assignment.id
        assert_equal @assignment.scanner_device_id, result.value.device.id
        assert_equal @invitation.reload.paired_user_id, result.value.operator.id
        assert result.value.session.active_at?
        assert_not_nil result.value.device.reload.last_seen_at
      end

      test "rejects missing and invalid bearer credentials" do
        missing = AuthenticateSession.call(token: nil, event: @event)
        invalid = AuthenticateSession.call(token: "not-a-scanner-token", event: @event)

        assert_equal "token_required", missing.error.code
        assert_equal "authentication_failed", invalid.error.code
      end

      test "rejects a session scoped to a different event" do
        result = AuthenticateSession.call(token: @token, event: events_events(:draft_concert))

        assert_equal "assignment_not_found", result.error.code
      end

      test "rechecks active collaborator ownership of a scanner device" do
        collaboration = @event.event_organizations.create!(
          organization: organizations_organizations(:three),
          type: "co_organizer",
          role: "operations",
          status: "active"
        )
        @assignment.scanner_device.update!(organization: collaboration.organization)

        assert authenticate.success?

        collaboration.update!(status: "revoked")
        result = authenticate

        assert_equal "device_scope_forbidden", result.error.code
      end

      test "rejects revoked session, device assignment, device, or event staff authority" do
        @session.update!(revoked_at: Time.current)
        assert_equal "authentication_failed", authenticate.error.code

        @session.update!(revoked_at: nil)
        @assignment.update!(status: "revoked")
        assert_equal "assignment_inactive", authenticate.error.code

        @assignment.update!(status: "active")
        @assignment.scanner_device.update!(status: "revoked", revoked_at: Time.current)
        assert_equal "device_inactive", authenticate.error.code

        @assignment.scanner_device.update!(status: "active", revoked_at: nil)
        @assignment.event_staff_assignment.update!(status: "revoked")
        assert_equal "operator_forbidden", authenticate.error.code
      end

      test "rejects expired sessions and assignments outside their access window" do
        future = Time.current + 2.minutes
        @session.update!(expires_at: Time.current + 1.minute)

        expired = AuthenticateSession.call(token: @token, event: @event, now: future)
        assert_equal "authentication_failed", expired.error.code

        @session.update!(expires_at: Time.current + 10.minutes)
        @assignment.update!(ends_at: Time.current + 30.seconds)
        outside_window = AuthenticateSession.call(token: @token, event: @event, now: Time.current + 1.minute)
        assert_equal "assignment_outside_window", outside_window.error.code
      end

      private

      def authenticate
        AuthenticateSession.call(token: @token, event: @event)
      end
    end
  end
end
