# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class ResendInvitationTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @invitation = create_invitation(phone: "0911234568", key: "resend-invite-create")
        @old_token = @invitation.token
        @old_code_digest = @invitation.pairing_code_digest
      end

      test "defines the pending-invitation resend command" do
        assert Scanners.const_defined?(:ResendInvitation, false)
      end

      test "rotates link and code, increments delivery revision, and queues one delivery" do
        result = resend(key: "resend-invite")

        assert result.success?, result.error&.message
        invitation = result.value.record
        assert_equal "pending", invitation.status
        assert_equal 2, invitation.delivery_revision
        refute_equal @old_token, result.value.token
        refute_equal @old_code_digest, invitation.pairing_code_digest
        assert_equal result.value.token, invitation.token
        assert_equal result.value.pairing_code, invitation.pairing_code
        assert_operator invitation.pairing_code_expires_at, :<=, 10.minutes.from_now
        assert_equal 2, Core::OutboxEvent.where(
          event_type: "ticketing.scanner_invitation.delivery_requested",
          aggregate_id: invitation.id
        ).count
      end

      test "replays a resend without another delivery or capability rotation" do
        results = []
        operation = -> { results << resend(key: "resend-replay") }
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
      end

      test "requires current event authority and rejects a terminal invitation" do
        forbidden = Ticketing::Scanners::ResendInvitation.call(
          invitation: @invitation,
          actor: core_users(:attendee),
          idempotency_key: "resend-forbidden"
        )
        assert_equal "invitation_forbidden", forbidden.error.code

        @invitation.update!(status: "expired", expired_at: Time.current, token_ciphertext: nil,
                                               pairing_code_ciphertext: nil)
        not_pending = resend(key: "resend-expired")
        assert_equal "scanner_invitation_not_resendable", not_pending.error.code
      end

      private

      def create_invitation(phone:, key:)
        result = CreateInvitation.call(
          event: @event,
          actor: @actor,
          phone:,
          starts_at: Time.current,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: key
        )
        raise result.error unless result.success?

        result.value.record
      end

      def resend(key:)
        ResendInvitation.call(
          invitation: @invitation,
          actor: @actor,
          idempotency_key: key
        )
      end
    end
  end
end
