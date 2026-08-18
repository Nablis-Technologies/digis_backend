# frozen_string_literal: true

require "test_helper"

module Commercial
  module Assignments
    class RecordExternalAcceptanceTest < ActiveSupport::TestCase
      include Commercial::FeeDefinitionTestHelpers

      setup do
        @organization = organizations_organizations(:one)
        @schedule = create_schedule(code: "external_acceptance_schedule")
        @version = create_version(@schedule)
        @actor = core_users(:super_admin)
        @assignment = CreateDraft.call(
          organization: @organization,
          actor: @actor,
          fee_schedule_version: @version,
          assignment_type: "mutual_agreement",
          reason: "External agreement",
          effective_from: 1.day.from_now
        ).value
      end

      test "records a controlled reference, actor, and time without contract contents" do
        accepted_at = 1.hour.ago

        result = RecordExternalAcceptance.call(
          assignment: @assignment,
          actor: @actor,
          external_reference: "contract-2026-001",
          accepted_at: accepted_at
        )

        assert result.success?, result.error&.message
        assignment = result.value
        assert_equal "pending_approval", assignment.status
        assert_equal "contract-2026-001", assignment.external_reference
        assert_equal @actor.id, assignment.external_accepted_by_id
        assert_equal accepted_at.to_i, assignment.external_accepted_at.to_i
        refute_includes assignment.attributes.keys, "contract_body"
        refute_includes assignment.attributes.keys, "contract_contents"
      end

      test "replays the same external reference without creating new evidence" do
        accepted_at = 1.hour.ago
        first = RecordExternalAcceptance.call(
          assignment: @assignment,
          actor: @actor,
          external_reference: "contract-2026-002",
          accepted_at: accepted_at
        )
        second = RecordExternalAcceptance.call(
          assignment: @assignment.reload,
          actor: @actor,
          external_reference: "contract-2026-002",
          accepted_at: accepted_at
        )

        assert_predicate first, :success?
        assert_predicate second, :success?
        assert_equal 1, Core::AuditLog.where(
          audit_key: "commercial-assignment-external-acceptance-#{@assignment.id}"
        ).count
      end

      test "rejects blank references and non-mutual assignments" do
        blank = RecordExternalAcceptance.call(
          assignment: @assignment,
          actor: @actor,
          external_reference: "   "
        )
        program_assignment = Commercial::Assignment.create!(
          organization: @organization,
          fee_schedule_version: @version,
          assignment_type: "platform_grant",
          status: "draft",
          reason: "Program assignment",
          effective_from: 1.day.from_now,
          risk_level: "low",
          baseline_resolution_digest: "a" * 64,
          created_by: @actor
        )
        wrong_type = RecordExternalAcceptance.call(
          assignment: program_assignment,
          actor: @actor,
          external_reference: "contract-2026-003"
        )

        assert blank.failure?
        assert_equal "external_reference_required", blank.error.code
        assert wrong_type.failure?
        assert_equal "assignment_type_not_mutual", wrong_type.error.code
      end
    end
  end
end
