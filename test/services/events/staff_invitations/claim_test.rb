# frozen_string_literal: true

require "test_helper"

module Events
  module StaffInvitations
    class ClaimTest < ActiveSupport::TestCase
      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @event = events_events(:ready_listing)
        @inviter = core_users(:support)
        @invitee = core_users(:attendee)
        @owner = core_users(:core_admin)
        Events::EventStaffAssignment.create!(
          event: @event,
          organization: @event.organization,
          user: @inviter,
          role: "manager",
          status: "active"
        )
      end

      test "claim creates only the scoped event assignment and accepts the invitation" do
        invitation, token = create_invitation
        global_roles = @invitee.roles.pluck(:id)
        organization_memberships = Organizations::Membership.where(
          organization: @event.organization,
          user: @invitee
        ).count

        result = claim(token:, key: "event-claim")

        assert_predicate result, :success?, result.error&.message
        assignment = result.value.assignment
        assert_equal @event.id, assignment.event_id
        assert_equal @event.organization_id, assignment.organization_id
        assert_equal @invitee.id, assignment.user_id
        assert_equal "staff", assignment.role
        assert_equal "active", assignment.status
        assert_equal "accepted", invitation.reload.status
        assert_equal @invitee.id, invitation.accepted_user_id
        assert_nil invitation.claim_token_ciphertext
        assert_equal global_roles, @invitee.roles.pluck(:id)
        assert_equal organization_memberships, Organizations::Membership.where(
          organization: @event.organization,
          user: @invitee
        ).count
        assert Core::AuditLog.exists?(auditable: invitation, action: "events.staff_invitation.accepted")
      end

      test "replays the same accepted claim without another assignment or audit" do
        invitation, token = create_invitation
        results = []
        operation = -> { results << claim(token:, key: "event-claim-replay") }
        counter = -> {
          @event.event_staff_assignments.count +
            Core::AuditLog.where(auditable: invitation, action: "events.staff_invitation.accepted").count
        }

        assert_idempotent(operation, counter:)

        first, replay = results
        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert replay.value.replayed?
        assert_equal first.value.assignment.id, replay.value.assignment.id
      end

      test "rejects a wrong phone and an unverified claimant without consuming the invite" do
        wrong_phone_invitation, wrong_phone_token = create_invitation(phone: "+251911999301")
        wrong_phone = claim(token: wrong_phone_token, key: "wrong-event-phone", actor: @owner)

        unverified_invitation, unverified_token = create_invitation(phone: @invitee.phone)
        @invitee.update!(verified_at: nil)
        unverified = claim(token: unverified_token, key: "unverified-event-phone")

        assert_equal "invitation_contact_mismatch", wrong_phone.error.code
        assert_equal "pending", wrong_phone_invitation.reload.status
        assert_equal "invitation_phone_unverified", unverified.error.code
        assert_equal "pending", unverified_invitation.reload.status
        assert_empty @event.event_staff_assignments.where(user: @owner)
        assert_empty @event.event_staff_assignments.where(user: @invitee)
      end

      test "fails closed when persisted invitation contact ciphertext cannot be decrypted" do
        invitation, token = create_invitation
        connection = ActiveRecord::Base.connection
        connection.execute(
          "UPDATE events_staff_invitations " \
          "SET contact_ciphertext = #{connection.quote("not-encrypted")} " \
          "WHERE id = #{connection.quote(invitation.id)}"
        )

        result = claim(token:, key: "corrupt-staff-contact-ciphertext")

        assert_equal "staff_invitation_claim_invalid", result.error.code
        assert_empty @event.event_staff_assignments.where(user: @invitee)
      end

      test "invitation remains claimable after its event manager inviter is revoked" do
        invitation, token = create_invitation(actor: @inviter)
        Events::EventStaffAssignment.where(event: @event, user: @inviter, role: "manager").update_all(status: "revoked")

        result = claim(token:, key: "event-owned-claim")

        assert_predicate result, :success?, result.error&.message
        assert_equal "accepted", invitation.reload.status
      end

      test "a different active general role requires the explicit role-change command" do
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @invitee,
          organization: @event.organization,
          role: "staff",
          status: "active"
        )
        invitation, token = create_invitation(role: "manager")

        result = claim(token:, key: "different-general-role")

        refute_predicate result, :success?
        assert_equal "staff_assignment_role_change_required", result.error.code
        assert_equal "pending", invitation.reload.status
        assert_equal [ "staff" ], @event.event_staff_assignments.where(user: @invitee, status: "active").pluck(:role)
      end

      test "scanner assignment remains independent from a general staff invitation" do
        scanner = Events::EventStaffAssignment.create!(
          event: @event,
          user: @invitee,
          organization: @event.organization,
          role: "scanner",
          status: "active"
        )
        invitation, token = create_invitation(role: "staff")

        result = claim(token:, key: "scanner-and-general-role")

        assert_predicate result, :success?, result.error&.message
        assert_equal "accepted", invitation.reload.status
        assert_equal "active", scanner.reload.status
        assert_equal %w[scanner staff], @event.event_staff_assignments.where(
          user: @invitee, status: "active"
        ).order(:role).pluck(:role)
      end

      test "copies an optional assignment expiry and rejects expired or cancelled invitations" do
        assignment_expires_at = 2.days.from_now
        invitation, token = create_invitation(assignment_expires_at:)
        accepted = claim(token:, key: "event-assignment-expiry")
        assert_predicate accepted, :success?, accepted.error&.message
        assert_equal assignment_expires_at.to_i, accepted.value.assignment.expires_at.to_i

        cancelled_invitation, cancelled_token = create_invitation(phone: "+251911999302")
        assignments_before_cancelled_claim = @event.event_staff_assignments.count
        @event.update!(status: "cancelled")
        cancelled = claim(token: cancelled_token, key: "cancelled-event-claim")

        assert_equal "event_not_invitable", cancelled.error.code
        assert_equal "pending", cancelled_invitation.reload.status
        assert_equal assignments_before_cancelled_claim, @event.event_staff_assignments.count
      end

      test "expires an overdue invitation synchronously before refusing its claim" do
        invitation, token = create_invitation
        expires_at = 1.minute.from_now
        invitation.update!(expires_at:)

        result = claim(token:, key: "expired-event-claim", at: expires_at + 1.second)

        assert_equal "staff_invitation_claim_invalid", result.error.code
        assert_equal "expired", invitation.reload.status
        assert_nil invitation.claim_token_ciphertext
        assert_empty @event.event_staff_assignments.where(user: @invitee)
      end

      test "rejects a claim key reused for a different capability" do
        _invitation, token = create_invitation
        first = claim(token:, key: "event-claim-conflict")
        second = claim(token: "f" * 64, key: "event-claim-conflict")

        assert_predicate first, :success?, first.error&.message
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 1, @event.event_staff_assignments.where(user: @invitee).count
      end

      private

      def create_invitation(phone: @invitee.phone, role: "staff", actor: @owner, assignment_expires_at: nil)
        result = Events::StaffInvitations::Create.call(
          event: @event,
          actor:,
          phone:,
          role:,
          assignment_expires_at:,
          idempotency_key: "event-invite-#{SecureRandom.hex(8)}",
          ip_address: "203.0.113.42"
        )
        assert_predicate result, :success?, result.error&.message
        [ result.value.record, result.value.token ]
      end

      def claim(token:, key:, actor: @invitee, at: Time.current)
        Events::StaffInvitations::Claim.call(
          token:,
          actor:,
          idempotency_key: key,
          ip_address: "203.0.113.42",
          at:
        )
      end
    end
  end
end
