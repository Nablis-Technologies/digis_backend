# frozen_string_literal: true

require "test_helper"

module Events
  module StaffInvitations
    class ExpireTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
      end

      test "expires only due pending staff invitations in the event scope and clears the token" do
        due_expiry = 1.minute.from_now
        due = create_invitation(phone: "+251911998801", expires_at: due_expiry)
        future = create_invitation(phone: "+251911998802", expires_at: 1.day.from_now)

        result = Events::StaffInvitations::Expire.call(
          event_id: @event.id,
          contact_digest: due.contact_digest,
          at: due_expiry + 1.second,
          limit: 10
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value
        assert_equal "expired", due.reload.status
        assert_nil due.claim_token_ciphertext
        assert_equal "pending", future.reload.status
        assert Core::AuditLog.exists?(auditable: due, action: "events.staff_invitation.expired")
      end

      test "bounds expiration to the requested batch size" do
        first = create_invitation(phone: "+251911998803", expires_at: 1.minute.from_now)
        second = create_invitation(phone: "+251911998804", expires_at: 2.minutes.from_now)

        result = Events::StaffInvitations::Expire.call(at: 3.minutes.from_now, limit: 1)

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value
        statuses = Events::StaffInvitation.where(id: [ first.id, second.id ]).pluck(:status)
        assert_equal 1, statuses.count("expired")
      end

      test "records no duplicate expiry audit on a replay" do
        expires_at = 1.minute.from_now
        invitation = create_invitation(phone: "+251911998805", expires_at:)
        operation = lambda do
          Events::StaffInvitations::Expire.call(
            event_id: @event.id,
            contact_digest: invitation.contact_digest,
            at: expires_at + 1.second,
            limit: 10
          )
        end

        assert_audit_idempotent(
          operation,
          action: "events.staff_invitation.expired",
          auditable_type: invitation.class.name,
          auditable_id: invitation.id
        )
      end

      private

      def create_invitation(phone:, expires_at:)
        contact = Core::InvitationContact.parse(phone:)
        token = SecureRandom.hex(32)
        Events::StaffInvitation.create!(
          event: @event,
          invited_by: @actor,
          role: "staff",
          contact_type: "phone",
          contact_ciphertext: contact.normalized_value,
          contact_digest: contact.digest_for(
            scope_type: Events::StaffInvitation::CONTACT_DIGEST_SCOPE,
            scope_id: @event.id
          ),
          status: "pending",
          claim_token_ciphertext: token,
          claim_token_digest: Events::StaffInvitation.claim_token_digest_for(token),
          delivery_status: "queued",
          delivery_revision: 1,
          delivery_attempts: 0,
          expires_at:,
          create_idempotency_key_digest: digest(SecureRandom.hex(16)),
          create_request_digest: digest(SecureRandom.hex(16))
        )
      end

      def digest(value)
        Core::KeyedDigest.digest(namespace: "test/events-staff-invitation", value:)
      end
    end
  end
end
