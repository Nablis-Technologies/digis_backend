# frozen_string_literal: true

require "test_helper"

module Events
  class StaffInvitationTest < ActiveSupport::TestCase
    test "accepts pending manager staff and contractor invitations" do
      %w[manager staff contractor].each do |role|
        invitation = build_invitation(role:)

        assert_predicate invitation, :valid?, invitation.errors.full_messages.join(", ")
      end
    end

    test "keeps scanner pairing outside general staff invitations" do
      invitation = build_invitation(role: "scanner")

      assert_not invitation.valid?
      assert_includes invitation.errors[:role], "is not included in the list"
    end

    test "keeps assignment expiry separate from the seven-day invitation expiry" do
      assignment_expiry = 2.days.from_now
      invitation = build_invitation(assignment_expires_at: assignment_expiry)

      assert_predicate invitation, :valid?, invitation.errors.full_messages.join(", ")
      assert_equal assignment_expiry, invitation.assignment_expires_at
      assert_operator invitation.expires_at, :>, invitation.assignment_expires_at

      expired_assignment = build_invitation(assignment_expires_at: 1.minute.ago)
      assert_not expired_assignment.valid?
      assert_includes expired_assignment.errors[:assignment_expires_at], "is invalid"
    end

    test "rejects unsupported contact types and malformed digests" do
      unsupported_contact = build_invitation(contact_type: "fax")
      assert_not unsupported_contact.valid?
      assert_includes unsupported_contact.errors[:contact_type], "is not included in the list"

      malformed_digest = build_invitation(contact_digest: "plaintext-phone")
      assert_not malformed_digest.valid?
      assert_includes malformed_digest.errors[:contact_digest], "is invalid"
    end

    test "masks destination and excludes encrypted values and digests from search" do
      invitation = build_invitation

      assert_equal "+2519***44", invitation.masked_contact
      searchable = Events::StaffInvitation.ransackable_attributes
      assert_includes searchable, "status"
      refute_includes searchable, "contact_ciphertext"
      refute_includes searchable, "claim_token_ciphertext"
      refute_includes searchable, "contact_digest"
    end

    test "derives the claim capability digest in the event invitation namespace" do
      token = "c" * 64

      assert_equal Core::KeyedDigest.digest(namespace: "events/staff-invitation-token", value: token),
        Events::StaffInvitation.claim_token_digest_for(token)
    end

    test "allows at most one pending invitation for an event and contact" do
      first = build_invitation
      assert first.save!, first.errors.full_messages.join(", ")

      duplicate = build_invitation(
        create_idempotency_key_digest: "e" * 64,
        create_request_digest: "f" * 64
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:contact_digest], "has already been taken"
    end

    private

    def build_invitation(**attributes)
      Events::StaffInvitation.new(
        {
          event: events_events(:ready_listing),
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
          expires_at: 7.days.from_now,
          assignment_expires_at: nil,
          create_idempotency_key_digest: "c" * 64,
          create_request_digest: "d" * 64,
          claim_idempotency_key_digest: nil,
          claim_request_digest: nil
        }.merge(attributes)
      )
    end
  end
end
