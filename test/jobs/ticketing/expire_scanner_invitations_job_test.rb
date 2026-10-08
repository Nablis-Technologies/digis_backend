# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ExpireScannerInvitationsJobTest < ActiveSupport::TestCase
    test "expires a due invitation and returns the number transitioned" do
      event = events_events(:ready_listing)
      created = Scanners::CreateInvitation.call(
        event:,
        actor: core_users(:super_admin),
        phone: "0911 23 45 84",
        starts_at: 3.hours.ago,
        ends_at: 3.days.from_now,
        expires_at: 1.hour.ago,
        idempotency_key: "expiry-job-invite-#{SecureRandom.hex(5)}",
        at: 2.hours.ago
      )
      raise created.error unless created.success?
      invitation = created.value.record

      count = ExpireScannerInvitationsJob.perform_now(at: Time.current)

      assert_equal 1, count
      assert_equal "expired", invitation.reload.status
      assert_nil invitation.token
      outbox = Core::OutboxEvent.find_by!(
        event_type: "ticketing.scanner_invitation.expired",
        aggregate_id: invitation.id
      )
      dispatched = Core::Outbox::Dispatch.call(event_id: outbox.id)

      assert dispatched.success?, dispatched.error&.message
      assert_predicate outbox.reload, :published_at?
    end
  end
end
