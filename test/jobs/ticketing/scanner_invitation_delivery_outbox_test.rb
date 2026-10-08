# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ScannerInvitationDeliveryOutboxTest < ActiveJob::TestCase
    test "outbox handler enqueues only invitation id and delivery revision" do
      event = events_events(:ready_listing)
      result = Ticketing::Scanners::CreateInvitation.call(
        event:,
        actor: core_users(:super_admin),
        phone: "0911 23 45 67",
        starts_at: Time.current,
        ends_at: 3.days.from_now,
        expires_at: 2.days.from_now,
        idempotency_key: "scanner-outbox-handler-#{SecureRandom.hex(5)}"
      )
      assert result.success?, result.error&.message

      invitation = result.value.record
      outbox_event = Core::OutboxEvent.find_by!(
        aggregate_id: invitation.id,
        event_type: "ticketing.scanner_invitation.delivery_requested"
      )
      assert_equal({
        "invitation_id" => invitation.id,
        "delivery_revision" => 1
      }, outbox_event.payload)
      refute outbox_event.payload.values.include?(result.value.token)
      refute outbox_event.payload.values.include?(result.value.pairing_code)

      assert_enqueued_with(
        job: Ticketing::DeliverScannerInvitationJob,
        args: [ invitation.id, 1 ]
      ) do
        Core::Outbox::Dispatch.call(event_id: outbox_event.id)
      end
      assert outbox_event.reload.published_at?
    end
  end
end
