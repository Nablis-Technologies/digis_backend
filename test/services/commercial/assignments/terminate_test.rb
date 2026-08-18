# frozen_string_literal: true

require "test_helper"

module Commercial
  module Assignments
    class TerminateTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(code: "assignment_terminate", effective_from: 2.days.ago)
        @assignment = Commercial::Assignment.create!(
          organization: organizations_organizations(:one), fee_schedule_version: @version,
          assignment_type: "platform_grant", status: "active", reason: "Terminate grant",
          effective_from: 2.days.ago, effective_until: 30.days.from_now, risk_level: "low",
          baseline_resolution_digest: "c" * 64, created_by: core_users(:super_admin),
          activated_by: core_users(:super_admin), activated_at: 1.day.ago
        )
      end

      test "terminates an assignment with idempotent evidence" do
        result = Terminate.call(
          assignment: @assignment, actor: core_users(:super_admin), reason: "No longer needed",
          idempotency_key: "assignment-terminate-1"
        )

        assert result.success?, result.error&.message
        assert_equal "terminated", result.value.status
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.assignment.terminated").count
      end
    end
  end
end
