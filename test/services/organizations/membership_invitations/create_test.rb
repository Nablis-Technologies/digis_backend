# frozen_string_literal: true

require "test_helper"

module Organizations
  module MembershipInvitations
    class CreateTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @organization = Organizations::Organization.create!(
          name: "Membership Invitation #{SecureRandom.hex(5)}",
          organizer_type: "individual",
          category: "conference"
        )
        @owner = core_users(:attendee)
        @admin = core_users(:support)
        @outsider = core_users(:core_admin)
        @organization.memberships.create!(user: @owner, role: "owner")
        @organization.memberships.create!(user: @admin, role: "admin")
      end

      test "owner creates a pending invitation without creating a user or membership" do
        phone = "+251911999001"
        user_count = Core::User.count
        membership_count = @organization.memberships.count

        result = create_invitation(actor: @owner, phone:, role: "staff", key: "owner-create-staff")

        assert_predicate result, :success?, result.error&.message
        invitation = result.value.record
        assert_equal "pending", invitation.status
        assert_equal "staff", invitation.role
        assert_equal "+251911999001", invitation.contact_ciphertext
        assert_equal 7.days.from_now.to_date, invitation.expires_at.to_date
        assert_equal 64, result.value.token.length
        assert_equal user_count, Core::User.count
        assert_equal membership_count, @organization.memberships.count
        assert_nil Core::User.find_by(phone: "+251911999001")

        event = Core::OutboxEvent.find_by!(
          event_type: "organizations.membership_invitation.delivery_requested",
          aggregate_id: invitation.id
        )
        assert_equal({
          "invitation_id" => invitation.id,
          "delivery_revision" => 1
        }, event.payload)
        audit = Core::AuditLog.find_by!(auditable: invitation, action: "organizations.membership_invitation.created")
        refute_includes audit.metadata.to_s, phone
        refute_includes audit.metadata.to_s, result.value.token
      end

      test "owner can invite an admin and an admin can invite staff only" do
        owner_result = create_invitation(actor: @owner, phone: "+251911999002", role: "admin", key: "owner-admin")
        admin_result = create_invitation(actor: @admin, phone: "+251911999003", role: "staff", key: "admin-staff")

        assert_predicate owner_result, :success?, owner_result.error&.message
        assert_predicate admin_result, :success?, admin_result.error&.message
      end

      test "rejects unauthorized actors and roles outside the invitation allowlist" do
        unauthorized = create_invitation(actor: @outsider, phone: "+251911999004", role: "staff", key: "outsider")
        owner_role = create_invitation(actor: @owner, phone: "+251911999005", role: "owner", key: "owner-role")
        admin_role = create_invitation(actor: @admin, phone: "+251911999006", role: "admin", key: "admin-role")

        assert_equal "invitation_forbidden", unauthorized.error.code
        assert_equal "invalid_role", owner_role.error.code
        assert_equal "invitation_forbidden", admin_role.error.code
      end

      test "requires exactly one valid contact channel and rejects email in phase one" do
        missing_contact = Organizations::MembershipInvitations::Create.call(
          organization: @organization, actor: @owner, role: "staff",
          idempotency_key: "missing-contact", ip_address: "203.0.113.10"
        )
        both_contacts = create_invitation(
          actor: @owner, phone: "+251911999007", email: "person@example.com", role: "staff", key: "both"
        )
        invalid_phone = create_invitation(actor: @owner, phone: "not-a-phone", role: "staff", key: "invalid-phone")
        email_phase_one = create_invitation(
          actor: @owner, email: "person@example.com", role: "staff", key: "email-phase-one"
        )

        assert_equal "invitation_contact_invalid", missing_contact.error.code
        assert_equal "invitation_contact_invalid", both_contacts.error.code
        assert_equal "invitation_contact_invalid", invalid_phone.error.code
        assert_equal "invitation_channel_not_enabled", email_phase_one.error.code
      end

      test "replays the same key and payload without creating another invite or delivery" do
        results = []
        operation = -> { results << create_invitation(actor: @owner, phone: "+251911999008", role: "staff", key: "create-replay") }
        counter = -> {
          Organizations::MembershipInvitation.count +
            Core::OutboxEvent.where(event_type: "organizations.membership_invitation.delivery_requested").count
        }

        assert_idempotent(operation, counter:)
        first, replay = results
        assert_predicate replay, :success?
        assert replay.value.replayed?
        assert_equal first.value.record.id, replay.value.record.id
        assert_equal first.value.token, replay.value.token
      end

      test "conflicts when an idempotency key is reused for a different contact" do
        first = create_invitation(actor: @owner, phone: "+251911999009", role: "staff", key: "create-conflict")
        second = create_invitation(actor: @owner, phone: "+251911999010", role: "staff", key: "create-conflict")

        assert_predicate first, :success?, first.error&.message
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 1, Organizations::MembershipInvitation.count
      end

      test "rejects a second pending invitation for the same normalized contact" do
        first = create_invitation(actor: @owner, phone: "0911999011", role: "staff", key: "duplicate-one")
        duplicate = create_invitation(actor: @owner, phone: "+251911999011", role: "staff", key: "duplicate-two")

        assert_predicate first, :success?, first.error&.message
        assert_equal "invitation_already_pending", duplicate.error.code
        assert_equal 1, Organizations::MembershipInvitation.count
      end

      test "expires a stale pending invitation before creating a replacement" do
        expires_at = 1.minute.from_now
        prior = Organizations::MembershipInvitation.create!(
          organization: @organization,
          invited_by: @owner,
          role: "staff",
          contact_type: "phone",
          contact_ciphertext: "+251911999012",
          contact_digest: Core::InvitationContact.parse(phone: "+251911999012").digest_for(
            scope_type: Organizations::MembershipInvitation::CONTACT_DIGEST_SCOPE,
            scope_id: @organization.id
          ),
          status: "pending",
          claim_token_ciphertext: "old-token",
          claim_token_digest: digest("old-token"),
          delivery_status: "queued",
          delivery_revision: 1,
          delivery_attempts: 0,
          expires_at:,
          create_idempotency_key_digest: digest("prior-create"),
          create_request_digest: digest("prior-request")
        )

        result = create_invitation(
          actor: @owner,
          phone: "+251911999012",
          role: "staff",
          key: "replacement",
          at: expires_at + 1.second
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "expired", prior.reload.status
        assert_nil prior.claim_token_ciphertext
        assert_equal 2, Organizations::MembershipInvitation.where(contact_digest: prior.contact_digest).count
      end

      private

      def create_invitation(actor:, role:, key:, phone: nil, email: nil, at: Time.current)
        Organizations::MembershipInvitations::Create.call(
          organization: @organization,
          actor:,
          phone:,
          email:,
          role:,
          idempotency_key: key,
          ip_address: "203.0.113.10",
          at:
        )
      end

      def digest(value)
        Core::KeyedDigest.digest(namespace: "test/membership-invitation-create", value:)
      end
    end
  end
end
