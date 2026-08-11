# frozen_string_literal: true

require "test_helper"

module Commercial
  module Assignments
    class SubmitTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @organization = organizations_organizations(:one)
        @version = create_simulatable_version(code: "assignment_submit", effective_from: 2.days.from_now)
        @assignment = Commercial::Assignment.create!(
          organization: @organization,
          fee_schedule_version: @version,
          assignment_type: "platform_grant",
          status: "draft",
          reason: "Bounded launch grant",
          effective_from: 2.days.from_now,
          effective_until: 30.days.from_now,
          risk_level: "medium",
          baseline_resolution_digest: "a" * 64,
          created_by: core_users(:super_admin)
        )
      end

      test "requires a passing assignment simulation" do
        result = Submit.call(assignment: @assignment, actor: core_users(:super_admin), idempotency_key: "assignment-submit-1")

        assert result.failure?
        assert_equal "simulation_required", result.error.code
      end

      test "moves a grant into approval after its current simulation" do
        result = run_passing_simulation(version: @version, assignment: @assignment, idempotency_key: "assignment-submit-sim")
        assert result.success?, result.error&.message

        result = Submit.call(assignment: @assignment, actor: core_users(:super_admin), idempotency_key: "assignment-submit-2")
        assert result.success?, result.error&.message
        assert_equal "pending_approval", result.value.status
      end
    end
  end
end
