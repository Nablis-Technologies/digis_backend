# frozen_string_literal: true

require "test_helper"

module Ticketing
  class CredentialClaims
    class AcceptTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow
        result = activate_delegated_ticket(assignments: { 1 => nil, 2 => nil, 3 => nil }, key: "claims-delegate")
        assert_predicate result, :success?, result.error&.message
        @credential = credential_at(1)
      end

      test "invites and accepts a recipient without exposing the token in persistence" do
        invitation = Ticketing::CredentialClaims::Invite.call(
          credential: @credential,
          actor: @owner,
          phone: @recipient.phone,
          idempotency_key: "claim-invite"
        )

        assert_predicate invitation, :success?, invitation.error&.message
        assert invitation.value.token.present?
        claim = invitation.value.claim
        assert_equal "pending", claim.status
        assert_equal @recipient.id, claim.invited_user_id
      assert_nil claim.attributes["token"]
        assert_nil @credential.reload.qr_token
      end

      test "accepts a claim only for its authenticated recipient and activates the credential" do
        invitation = invite_claim

        wrong_user = Ticketing::CredentialClaims::Accept.call(
          token: invitation.value.token,
          actor: @other_user
        )
        assert_predicate wrong_user, :failure?
        assert_equal "claim_recipient_mismatch", wrong_user.error.code

        accepted = Ticketing::CredentialClaims::Accept.call(
          token: invitation.value.token,
          actor: @recipient
        )

        assert_predicate accepted, :success?, accepted.error&.message
        assert_equal "accepted", accepted.value.claim.status
        assert_equal "active", accepted.value.credential.status
        assert_equal @recipient.id, accepted.value.credential.holder_user_id
        assert_equal "claimed", accepted.value.credential.admission_slot.reload.assignment_status
        assert accepted.value.credential.attendee_index_entry.present?
      end

      test "replays acceptance for the same recipient without creating another index entry" do
        invitation = invite_claim
        first = Ticketing::CredentialClaims::Accept.call(token: invitation.value.token, actor: @recipient)
        second = Ticketing::CredentialClaims::Accept.call(token: invitation.value.token, actor: @recipient)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal first.value.credential.id, second.value.credential.id
        assert_equal 1, Ticketing::AttendeeIndexEntry.where(credential_id: @credential.id).count
      end

      test "does not activate while a personal requirement is pending" do
        create_pending_personal_requirement
        invitation = invite_claim

        accepted = Ticketing::CredentialClaims::Accept.call(
          token: invitation.value.token,
          actor: @recipient
        )

        assert_predicate accepted, :success?, accepted.error&.message
        assert_equal "pending_requirements", accepted.value.credential.status
        assert_nil accepted.value.credential.qr_token
        assert_empty Ticketing::AttendeeIndexEntry.where(credential_id: @credential.id)
      end

      private

      def invite_claim
        Ticketing::CredentialClaims::Invite.call(
          credential: @credential,
          actor: @owner,
          phone: @recipient.phone,
          idempotency_key: "claim-invite-#{SecureRandom.hex(4)}"
        ).tap { |result| assert_predicate result, :success?, result.error&.message }
      end

      def create_pending_personal_requirement
        document = Events::ConsentDocument.create!(
          event: @event,
          name: "Claim requirement #{SecureRandom.hex(4)}",
          type: "liability_waiver",
          created_by: @manager
        )
        version = document.versions.create!(
          version: 1,
          title: "Claim terms",
          body: "Claim terms body",
          content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
            type: document.type, title: "Claim terms", body: "Claim terms body"
          ),
          required: true,
          acceptance_scope: "admission_slot",
          status: "draft",
          created_by: @manager
        )
        version.update!(status: "published", published_by: @manager, published_at: Time.current)
        requirement = Ticketing::RegistrationConsentRequirement.create!(
          registration: @registration,
          consent_document_version: version,
          required: true,
          acceptance_scope: "admission_slot",
          package_unit_number: 1,
          admission_position: 1,
          subject_user: @recipient,
          status: "pending",
          required_at: Time.current,
          required_reason: "initial_submission"
        )
        assert requirement.persisted?
      end
    end
  end
end
