# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class RevokeInvitationTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        result = CreateInvitation.call(
          event: @event,
          actor: @actor,
          phone: "0911234568",
          starts_at: Time.current,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: "revoke-invite-create"
        )
        raise result.error unless result.success?

        @invitation = result.value.record
      end

      test "defines the scanner-invitation revoke command" do
        assert Scanners.const_defined?(:RevokeInvitation, false)
      end

      test "revokes pending pairing material with an auditable idempotent transition" do
        result = revoke(key: "revoke-invite")

        assert result.success?, result.error&.message
        assert_equal "revoked", @invitation.reload.status
        assert_nil @invitation.token
        assert_nil @invitation.pairing_code
        assert_equal 1, Core::AuditLog.where(
          action: "ticketing.scanner_invitation.revoked",
          auditable: @invitation
        ).count
        assert @invitation.token_digest.present?
        refute @invitation.pairable_at?
      end

      test "replaying revoke does not write another audit transition" do
        result = nil
        operation = -> { result = revoke(key: "revoke-invite-replay") }
        assert_audit_idempotent(
          operation,
          action: "ticketing.scanner_invitation.revoked",
          auditable_type: "Ticketing::ScannerInvitation",
          auditable_id: -> { @invitation.id }
        )
        assert result.success?, result.error&.message
      end

      test "rejects revoking a terminal invitation through the unclaimed-invite action" do
        @invitation.update!(status: "expired", expired_at: Time.current, token_ciphertext: nil,
                                               pairing_code_ciphertext: nil)

        result = revoke(key: "revoke-expired-invite")

        assert_equal "scanner_invitation_not_revocable", result.error.code
      end

      private

      def revoke(key:)
        RevokeInvitation.call(invitation: @invitation, actor: @actor, idempotency_key: key)
      end
    end
  end
end
