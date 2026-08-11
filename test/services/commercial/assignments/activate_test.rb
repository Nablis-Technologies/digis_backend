# frozen_string_literal: true

require "test_helper"

module Commercial
  module Assignments
    class ActivateTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(code: "assignment_activate", effective_from: 2.days.ago)
        @assignment = Commercial::Assignment.create!(
          organization: organizations_organizations(:one), fee_schedule_version: @version,
          assignment_type: "mutual_agreement", status: "scheduled",
          reason: "Accepted mutual terms", effective_from: 2.days.ago,
          risk_level: "high", created_by: core_users(:super_admin),
          external_reference: "contract-activate-1",
          external_accepted_by: core_users(:super_admin), external_accepted_at: 1.day.ago
        )
        run_passing_simulation(version: @version, assignment: @assignment, idempotency_key: "assignment-activate-sim")
        Commercial::Approval.create!(
          target: @assignment, decision: "approved", reason: "Accepted terms reviewed",
          definition_digest: @version.definition_digest, actor: core_users(:super_admin),
          decided_at: Time.current, idempotency_key_digest: "e" * 64, request_fingerprint: "f" * 64
        )
      end

      test "activates accepted assignments with one transition audit" do
        result = Activate.call(
          assignment: @assignment, actor: core_users(:super_admin), idempotency_key: "assignment-activate-2"
        )

        assert result.success?, result.error&.message
        assert_equal "active", result.value.status
        assert_equal 1, Core::AuditLog.where(action: "commercial.assignment.activated").count
      end
    end
  end
end
