# frozen_string_literal: true

require "test_helper"

module Commercial
  module Versions
    class ApproveTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(
          code: "version_approve",
          schedule_type: "platform_default",
          effective_from: 2.days.from_now
        )
        run_passing_simulation(version: @version, idempotency_key: "version-approve-sim")
        Submit.call(version: @version, actor: core_users(:super_admin), idempotency_key: "version-approve-submit")
      end

      test "requires a distinct checker for platform defaults" do
        result = Approve.call(
          version: @version, actor: core_users(:super_admin), reason: "Same actor",
          idempotency_key: "version-approve-1"
        )

        assert result.failure?
        assert_equal "maker_checker_required", result.error.code
      end

      test "records an approval and freezes the definition" do
        checker = authorize(core_users(:core_admin), "commercial.approve")
        result = Approve.call(
          version: @version, actor: checker, reason: "Second-person review",
          idempotency_key: "version-approve-2"
        )

        assert result.success?, result.error&.message
        assert_equal "approved", result.value.status
        assert_equal 1, Commercial::Approval.where(target: @version, decision: "approved").count
        assert_raises(ActiveRecord::RecordInvalid) { @version.reload.update!(acceptance_policy: "explicit") }
      end

      test "records a security event for an authorized break-glass approval" do
        checker = authorize(core_users(:core_admin), "commercial.approve")
        authorize(checker, "commercial.break_glass")

        result = Approve.call(
          version: @version, actor: checker, reason: "Emergency pricing correction",
          idempotency_key: "version-approve-break-glass", break_glass: true
        )

        assert result.success?, result.error&.message
        assert_equal 1, Core::AuditLog.where(action: "commercial.security.break_glass").count
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.security.break_glass").count
      end

      test "requires a reason for break-glass approval" do
        result = Approve.call(
          version: @version, actor: core_users(:super_admin), reason: " ",
          idempotency_key: "version-approve-break-glass-no-reason", break_glass: true
        )

        assert result.failure?
        assert_equal "break_glass_reason_required", result.error.code
      end
    end
  end
end
