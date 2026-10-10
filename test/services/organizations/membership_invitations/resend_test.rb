# frozen_string_literal: true

require "test_helper"

module Organizations
  module MembershipInvitations
    class ResendTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @organization = Organizations::Organization.create!(
          name: "Membership Resend #{SecureRandom.hex(5)}",
          organizer_type: "individual",
          category: "conference"
        )
        @owner = core_users(:attendee)
        @outsider = core_users(:core_admin)
        @organization.memberships.create!(user: @owner, role: "owner")
      end

      test "rotates the pending claim token and increments delivery revision without extending expiry" do
        invitation, old_token = create_pending
        old_digest = invitation.claim_token_digest
        original_expiry = invitation.expires_at
        previous_delivery_count = delivery_count

        result = resend(invitation:, actor: @owner, key: "resend-rotate")

        assert_predicate result, :success?, result.error&.message
        assert_equal "pending", invitation.reload.status
        assert_equal 2, invitation.delivery_revision
        assert_equal original_expiry, invitation.expires_at
        assert_not_equal old_digest, invitation.claim_token_digest
        assert_not_equal old_token, result.value.token
        assert_equal previous_delivery_count + 1, delivery_count
        audit = Core::AuditLog.find_by!(auditable: invitation, action: "organizations.membership_invitation.resent")
        refute_includes audit.metadata.to_s, old_token
        refute_includes audit.metadata.to_s, result.value.token
      end

      test "replays resend without rotating or publishing another delivery" do
        invitation, = create_pending
        results = []
        operation = -> { results << resend(invitation:, actor: @owner, key: "resend-replay") }
        counter = -> { invitation.reload.delivery_revision + delivery_count }

        assert_idempotent(operation, counter:)
        assert_predicate results.first, :success?, results.first.error&.message
        assert_predicate results.last, :success?, results.last.error&.message
        assert results.last.value.replayed?
        assert_equal results.first.value.token, results.last.value.token
      end

      test "rejects resend from an actor who cannot manage the invitation" do
        invitation, = create_pending

        result = resend(invitation:, actor: @outsider, key: "resend-forbidden")

        assert_equal "invitation_forbidden", result.error.code
        assert_equal 1, invitation.reload.delivery_revision
      end

      test "rejects resend after invitation expiry" do
        invitation, = create_pending(expires_at: 1.minute.from_now)

        result = resend(invitation:, actor: @owner, key: "resend-expired", at: invitation.expires_at + 1.second)

        assert_equal "invitation_not_resendable", result.error.code
        assert_equal 1, invitation.reload.delivery_revision
      end

      private

      def create_pending(expires_at: 7.days.from_now)
        phone = "+2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        result = Organizations::MembershipInvitations::Create.call(
          organization: @organization,
          actor: @owner,
          phone:,
          role: "staff",
          idempotency_key: "resend-create-#{SecureRandom.hex(8)}",
          ip_address: "203.0.113.11",
          at: expires_at - 7.days
        )
        assert_predicate result, :success?, result.error&.message

        [ result.value.record, result.value.token ]
      end

      def resend(invitation:, actor:, key:, at: Time.current)
        Organizations::MembershipInvitations::Resend.call(
          invitation:,
          actor:,
          idempotency_key: key,
          ip_address: "203.0.113.12",
          at:
        )
      end

      def delivery_count
        Core::OutboxEvent.where(event_type: "organizations.membership_invitation.delivery_requested").count
      end
    end
  end
end
