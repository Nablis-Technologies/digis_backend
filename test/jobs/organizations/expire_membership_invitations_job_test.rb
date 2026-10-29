# frozen_string_literal: true

require "test_helper"

module Organizations
  class ExpireMembershipInvitationsJobTest < ActiveSupport::TestCase
    test "expires due pending membership invitations in a bounded job run" do
      invitation = create_invitation(expires_at: 1.minute.from_now)

      travel_to(invitation.expires_at + 1.second) do
        assert_equal 1, ExpireMembershipInvitationsJob.perform_now(limit: 10)
      end

      assert_equal "expired", invitation.reload.status
      assert_nil invitation.claim_token_ciphertext
    end

    test "is an idempotent no-op when no invitation is due" do
      assert_equal 0, ExpireMembershipInvitationsJob.perform_now(limit: 10)
    end

    private

    def create_invitation(expires_at:)
      organization = organizations_organizations(:one)
      contact = Core::InvitationContact.parse(phone: "+251911998877")
      token = SecureRandom.hex(32)
      Organizations::MembershipInvitation.create!(
        organization:,
        invited_by: core_users(:super_admin),
        role: "staff",
        contact_type: "phone",
        contact_ciphertext: contact.normalized_value,
        contact_digest: contact.digest_for(
          scope_type: Organizations::MembershipInvitation::CONTACT_DIGEST_SCOPE,
          scope_id: organization.id
        ),
        status: "pending",
        claim_token_ciphertext: token,
        claim_token_digest: Organizations::MembershipInvitation.claim_token_digest_for(token),
        delivery_status: "queued",
        delivery_revision: 1,
        delivery_attempts: 0,
        expires_at:,
        create_idempotency_key_digest: Core::KeyedDigest.digest(
          namespace: "test/membership-invitation-create", value: SecureRandom.hex(16)
        ),
        create_request_digest: Core::KeyedDigest.digest(
          namespace: "test/membership-invitation-request", value: SecureRandom.hex(16)
        )
      )
    end
  end
end
