# frozen_string_literal: true

require "test_helper"

module Organizations
  class MembershipInvitationTest < ActiveSupport::TestCase
    test "accepts pending staff and admin invitations with encrypted contact and claim token" do
      [ "staff", "admin" ].each do |role|
        invitation = build_invitation(role:)

        assert_predicate invitation, :valid?, invitation.errors.full_messages.join(", ")
        assert_equal "+251911223344", invitation.contact_ciphertext
        assert_equal "claim-token", invitation.claim_token_ciphertext
      end
    end

    test "rejects owner invitations, unsupported contact types and malformed digests" do
      owner_invitation = build_invitation(role: "owner")
      assert_not owner_invitation.valid?
      assert_includes owner_invitation.errors[:role], "is not included in the list"

      unsupported_contact = build_invitation(contact_type: "fax")
      assert_not unsupported_contact.valid?
      assert_includes unsupported_contact.errors[:contact_type], "is not included in the list"

      malformed_digest = build_invitation(contact_digest: "plaintext-phone")
      assert_not malformed_digest.valid?
      assert_includes malformed_digest.errors[:contact_digest], "is invalid"
    end

    test "accepts email as a stored contact channel for the later email phase" do
      invitation = build_invitation(contact_type: "email", contact_ciphertext: "teammate@example.com")

      assert_predicate invitation, :valid?, invitation.errors.full_messages.join(", ")
    end

    test "masks the destination and exposes only safe searchable fields" do
      invitation = build_invitation

      assert_equal "+2519***44", invitation.masked_contact
      assert_includes Organizations::MembershipInvitation.ransackable_attributes, "status"
      refute_includes Organizations::MembershipInvitation.ransackable_attributes, "contact_ciphertext"
      refute_includes Organizations::MembershipInvitation.ransackable_attributes, "claim_token_ciphertext"
      refute_includes Organizations::MembershipInvitation.ransackable_attributes, "contact_digest"
    end

    test "allows at most one pending invitation for an organization and contact" do
      first = build_invitation
      assert first.save!, first.errors.full_messages.join(", ")

      duplicate = build_invitation(
        create_idempotency_key_digest: "e" * 64,
        create_request_digest: "f" * 64
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:contact_digest], "has already been taken"
    end

    test "requires a bounded expiry and encrypted capability only while pending" do
      no_expiry = build_invitation(expires_at: nil)
      assert_not no_expiry.valid?
      assert_includes no_expiry.errors[:expires_at], "can't be blank"

      accepted = build_invitation(
        status: "accepted",
        accepted_user: core_users(:attendee),
        accepted_at: Time.current,
        claim_idempotency_key_digest: "e" * 64,
        claim_request_digest: "f" * 64,
        claim_token_ciphertext: nil
      )
      assert_predicate accepted, :valid?, accepted.errors.full_messages.join(", ")
    end

    private

    def build_invitation(**attributes)
      Organizations::MembershipInvitation.new(
        {
          organization: organizations_organizations(:one),
          invited_by: core_users(:super_admin),
          contact_type: "phone",
          contact_ciphertext: "+251911223344",
          contact_digest: "a" * 64,
          role: "staff",
          status: "pending",
          claim_token_ciphertext: "claim-token",
          claim_token_digest: "b" * 64,
          delivery_status: "queued",
          delivery_revision: 1,
          delivery_attempts: 0,
          create_idempotency_key_digest: "c" * 64,
          create_request_digest: "d" * 64,
          claim_idempotency_key_digest: nil,
          claim_request_digest: nil,
          expires_at: 7.days.from_now
        }.merge(attributes)
      )
    end
  end
end
