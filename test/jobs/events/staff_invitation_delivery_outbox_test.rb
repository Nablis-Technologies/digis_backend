# frozen_string_literal: true

require "test_helper"

module Events
  class StaffInvitationDeliveryOutboxTest < ActiveJob::TestCase
    test "outbox handler enqueues only the invitation id and delivery revision" do
      event = events_events(:ready_listing)
      result = Events::StaffInvitations::Create.call(
        event:,
        actor: core_users(:core_admin),
        phone: "+251911999702",
        role: "staff",
        idempotency_key: "staff-delivery-outbox",
        ip_address: "203.0.113.81"
      )
      assert_predicate result, :success?, result.error&.message

      invitation = result.value.record
      outbox_event = Core::OutboxEvent.find_by!(
        aggregate_id: invitation.id,
        event_type: "events.staff_invitation.delivery_requested"
      )
      assert_equal({ "invitation_id" => invitation.id, "delivery_revision" => 1 }, outbox_event.payload)
      refute_includes outbox_event.payload.values, result.value.token

      assert_enqueued_with(
        job: Events::DeliverStaffInvitationJob,
        args: [ invitation.id, 1 ]
      ) do
        Core::Outbox::Dispatch.call(event_id: outbox_event.id)
      end
      assert outbox_event.reload.published_at?
    end
  end
end
