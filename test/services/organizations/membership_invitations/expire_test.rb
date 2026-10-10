# frozen_string_literal: true

require "test_helper"

module Organizations
  module MembershipInvitations
    class ExpireTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:one)
        @actor = core_users(:super_admin)
      end

      test "expires only due pending invitations in the requested scope and clears the token" do
        due_expiry = 1.minute.from_now
        due = create_invitation(contact_digest: digest("due"), expires_at: due_expiry)
        future = create_invitation(contact_digest: digest("future"), expires_at: 1.day.from_now)

        result = Organizations::MembershipInvitations::Expire.call(
          organization_id: @organization.id,
          contact_digest: due.contact_digest,
          at: due_expiry + 1.second,
          limit: 10
        )

        assert_predicate result, :success?
        assert_equal 1, result.value
        assert_equal "expired", due.reload.status
        assert_nil due.claim_token_ciphertext
        assert_equal "pending", future.reload.status
        assert Core::AuditLog.exists?(auditable: due, action: "organizations.membership_invitation.expired")
      end

      test "bounds expiration to the requested batch size" do
        later = create_invitation(contact_digest: digest("first"), expires_at: 2.minutes.from_now)
        earlier = create_invitation(contact_digest: digest("second"), expires_at: 1.minute.from_now)

        result = Organizations::MembershipInvitations::Expire.call(at: 3.minutes.from_now, limit: 1)

        assert_predicate result, :success?
        assert_equal 1, result.value
        statuses = Organizations::MembershipInvitation.where(id: [ later.id, earlier.id ]).pluck(:id, :status).to_h
        assert_equal "expired", statuses.fetch(earlier.id)
        assert_equal "pending", statuses.fetch(later.id)
      end

      test "records no duplicate expiration audit on a replay" do
        expires_at = 1.minute.from_now
        invitation = create_invitation(contact_digest: digest("replay"), expires_at:)
        operation = lambda do
          Organizations::MembershipInvitations::Expire.call(
            organization_id: @organization.id,
            contact_digest: invitation.contact_digest,
            at: expires_at + 1.second,
            limit: 10
          )
        end

        assert_audit_idempotent(
          operation,
          action: "organizations.membership_invitation.expired",
          auditable_type: invitation.class.name,
          auditable_id: invitation.id
        )
      end

      private

      def create_invitation(contact_digest:, expires_at:)
        token = "token-#{SecureRandom.hex(8)}"
        Organizations::MembershipInvitation.create!(
          organization: @organization,
          invited_by: @actor,
          role: "staff",
          contact_type: "phone",
          contact_ciphertext: "+251911223344",
          contact_digest:,
          status: "pending",
          claim_token_ciphertext: token,
          claim_token_digest: digest(token),
          delivery_status: "queued",
          delivery_revision: 1,
          delivery_attempts: 0,
          expires_at:,
          create_idempotency_key_digest: digest(SecureRandom.hex(16)),
          create_request_digest: digest(SecureRandom.hex(16))
        )
      end

      def digest(value)
        Core::KeyedDigest.digest(namespace: "test/membership-invitation", value:)
      end
    end
  end
end
