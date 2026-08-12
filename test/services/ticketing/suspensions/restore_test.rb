# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Suspensions
    class RestoreTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow
        @opened = Ticketing::Suspensions::Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
        ).value
      end

      test "restores admission without changing ownership or financial history" do
        opened_version = Ticketing::Revocation.find_by!(ticket_id: @opened.ticket_id).revocation_version
        result = Restore.call(
          suspension: @opened,
          actor: @manager,
          resolution_reason: "review_cleared",
          idempotency_key: "suspension-restore-#{SecureRandom.hex(8)}"
        )

        assert_predicate result, :success?, result.error&.message
        suspension = result.value
        ticket = @ticket.reload

        assert_equal "restored", suspension.status
        assert_equal @manager.id, suspension.resolved_by_id
        assert_equal "review_cleared", suspension.resolution_reason
        assert_not_nil suspension.resolved_at
        assert_equal "active", ticket.status
        assert_equal @owner.id, ticket.owner_user_id
        assert_not ticket.revocation.is_dead
        assert_not ticket.revocation.is_suspended
        assert_operator ticket.revocation.revocation_version, :>, opened_version
      end

      test "replays a restore command without editing the historical case" do
        key = "suspension-restore-#{SecureRandom.hex(8)}"
        first = Restore.call(
          suspension: @opened,
          actor: @manager,
          resolution_reason: "review_cleared",
          idempotency_key: key
        )
        second = Restore.call(
          suspension: @opened,
          actor: @manager,
          resolution_reason: "review_cleared",
          idempotency_key: key
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal first.value.id, second.value.id
        assert_equal 1, Ticketing::TicketSuspension.where(id: @opened.id).count
        assert_equal 1, Core::AuditLog.where(
          auditable_type: "Ticketing::TicketSuspension",
          auditable_id: @opened.id,
          action: "ticketing.ticket_suspension.restored"
        ).count
      end

      test "does not restore a package that has become terminal" do
        @ticket.update!(status: "void")
        @ticket.revocation.update!(is_dead: true, is_suspended: false)

        result = Restore.call(
          suspension: @opened,
          actor: @manager,
          resolution_reason: "review_cleared",
          idempotency_key: "suspension-restore-#{SecureRandom.hex(8)}"
        )

        assert_predicate result, :failure?
        assert_equal "suspension_not_restorable", result.error.code
        assert_equal "active", @opened.reload.status
        assert @ticket.reload.revocation.is_dead
      end
    end
  end
end
