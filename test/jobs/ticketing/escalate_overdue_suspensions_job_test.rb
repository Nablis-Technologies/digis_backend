# frozen_string_literal: true

require "test_helper"

module Ticketing
  class EscalateOverdueSuspensionsJobTest < ActiveJob::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow
      @suspension = Ticketing::Suspensions::Open.call(
        ticket: @ticket,
        actor: @manager,
        reason_code: "suspected_fraud",
        review_deadline_at: 3.days.from_now,
        idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
      ).value
      @suspension.update_columns(review_deadline_at: 1.minute.ago)
    end

    test "marks overdue review for escalation without restoring admission" do
      assert_nothing_raised { Ticketing::EscalateOverdueSuspensionsJob.perform_now }

      assert_equal "expired", @suspension.reload.status
      assert_equal "active", @ticket.reload.status
      assert @ticket.revocation.is_suspended
      assert_not @ticket.revocation.is_dead
      assert_equal "review_deadline_expired", @suspension.resolution_reason
      assert_not_nil @suspension.resolved_by_id
      assert Core::AuditLog.exists?(
        auditable_type: "Ticketing::TicketSuspension",
        auditable_id: @suspension.id,
        action: "ticketing.ticket_suspension.expired"
      )
    end
  end
end
