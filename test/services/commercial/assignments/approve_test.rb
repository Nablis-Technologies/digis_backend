# frozen_string_literal: true

require "test_helper"

module Commercial
  module Assignments
    class ApproveTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(code: "assignment_approve", effective_from: 2.days.from_now)
        @assignment = Commercial::Assignment.create!(
          organization: organizations_organizations(:one), fee_schedule_version: @version,
          assignment_type: "platform_grant", status: "pending_approval",
          reason: "Bounded beneficial grant", effective_from: 2.days.from_now,
          effective_until: 30.days.from_now, risk_level: "medium",
          baseline_resolution_digest: "b" * 64, created_by: core_users(:super_admin)
        )
        run_passing_simulation(
          version: @version, assignment: @assignment, idempotency_key: "assignment-approve-sim",
          scenario: {
            resolution_context: simulation_scenario,
            baseline: beneficial_matrix,
            proposed: beneficial_matrix
          }
        )
      end

      test "allows one authorized finance actor for a bounded beneficial grant" do
        result = Approve.call(
          assignment: @assignment, actor: core_users(:super_admin), reason: "Benefit verified",
          idempotency_key: "assignment-approve-1"
        )

        assert result.success?, result.error&.message
        assert_equal "scheduled", result.value.status
      end

      test "requires a checker for mutual agreements" do
        @assignment.update_columns(
          assignment_type: "mutual_agreement", risk_level: "high", status: "pending_approval",
          external_reference: "contract-1", external_accepted_by_id: core_users(:super_admin).id,
          external_accepted_at: Time.current
        )

        result = Approve.call(
          assignment: @assignment, actor: core_users(:super_admin), reason: "Mutual review",
          idempotency_key: "assignment-approve-2"
        )

        assert result.failure?
        assert_equal "maker_checker_required", result.error.code
      end

      test "break glass cannot bypass mutual acceptance evidence" do
        @assignment.update_columns(
          assignment_type: "mutual_agreement", risk_level: "high", status: "pending_approval",
          external_reference: nil, external_accepted_by_id: nil, external_accepted_at: nil
        )

        result = Approve.call(
          assignment: @assignment, actor: core_users(:super_admin), reason: "Emergency review",
          idempotency_key: "assignment-approve-break-glass", break_glass: true
        )

        assert result.failure?
        assert_equal "break_glass_acceptance_forbidden", result.error.code
        assert_equal 0, Core::AuditLog.where(action: "commercial.security.break_glass").count
      end

      private

      def beneficial_matrix
        {
          "online:ETB" => {
            "platform_commission" => {
              "rate_bps" => 750, "charged_to" => "organizer", "funded_by" => "organizer"
            }
          }
        }
      end
    end
  end
end
