# frozen_string_literal: true

require "test_helper"

module Organizations
  class MembershipInvitationDeliveryOutboxTest < ActiveJob::TestCase
    test "outbox handler enqueues only the invitation id and delivery revision" do
      organization = Organizations::Organization.create!(
        name: "Invitation Outbox #{SecureRandom.hex(5)}",
        organizer_type: "individual",
        category: "conference"
      )
      actor = core_users(:attendee)
      organization.memberships.create!(user: actor, role: "owner")
      result = Organizations::MembershipInvitations::Create.call(
        organization:,
        actor:,
        phone: "+251911999701",
        role: "staff",
        idempotency_key: "membership-delivery-outbox",
        ip_address: "203.0.113.80"
      )
      assert_predicate result, :success?, result.error&.message

      invitation = result.value.record
      outbox_event = Core::OutboxEvent.find_by!(
        aggregate_id: invitation.id,
        event_type: "organizations.membership_invitation.delivery_requested"
      )
      assert_equal({ "invitation_id" => invitation.id, "delivery_revision" => 1 }, outbox_event.payload)
      refute_includes outbox_event.payload.values, result.value.token

      assert_enqueued_with(
        job: Organizations::DeliverMembershipInvitationJob,
        args: [ invitation.id, 1 ]
      ) do
        Core::Outbox::Dispatch.call(event_id: outbox_event.id)
      end
      assert outbox_event.reload.published_at?
    end
  end
end
