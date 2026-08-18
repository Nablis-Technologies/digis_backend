# frozen_string_literal: true

require "test_helper"

module Commercial
  module Assignments
    class CreateDraftTest < ActiveSupport::TestCase
      include Commercial::FeeDefinitionTestHelpers

      setup do
        @organization = organizations_organizations(:one)
        @other_organization = organizations_organizations(:two)
        @event = events_events(:draft_concert)
        @schedule = create_schedule(code: "draft_assignment_schedule")
        @version = create_version(@schedule)
        @actor = core_users(:super_admin)
      end

      test "creates a platform grant without acceptance and stores its baseline proof" do
        result = CreateDraft.call(
          organization: @organization,
          actor: @actor,
          fee_schedule_version: @version,
          assignment_type: "platform_grant",
          reason: "Launch support for the first event",
          effective_from: 1.day.from_now,
          effective_until: 30.days.from_now,
          baseline_resolution_digest: "a" * 64
        )

        assert result.success?, result.error&.message
        assignment = result.value
        assert_equal "draft", assignment.status
        assert_equal "platform_grant", assignment.assignment_type
        assert_equal "a" * 64, assignment.baseline_resolution_digest
        assert_equal "Launch support for the first event", assignment.reason
        assert_nil assignment.legal_acceptance_id
      end

      test "rejects an event from another organization without mutation" do
        before_count = Assignment.count

        result = CreateDraft.call(
          organization: @other_organization,
          event: @event,
          actor: @actor,
          fee_schedule_version: @version,
          assignment_type: "platform_grant",
          reason: "Invalid event target",
          effective_from: 1.day.from_now,
          baseline_resolution_digest: "b" * 64
        )

        assert result.failure?
        assert_equal "event_organization_mismatch", result.error.code
        assert_equal before_count, Assignment.count
      end

      test "creates a mutual agreement in pending acceptance with calculated risk" do
        result = CreateDraft.call(
          organization: @organization,
          actor: @actor,
          fee_schedule_version: @version,
          assignment_type: "mutual_agreement",
          reason: "Negotiated organizer terms",
          effective_from: 1.day.from_now
        )

        assert result.success?, result.error&.message
        assignment = result.value
        assert_equal "pending_acceptance", assignment.status
        assert_equal "high", assignment.risk_level
      end

      test "rejects a platform grant without a valid baseline digest" do
        result = CreateDraft.call(
          organization: @organization,
          actor: @actor,
          fee_schedule_version: @version,
          assignment_type: "platform_grant",
          reason: "Missing proof",
          effective_from: 1.day.from_now
        )

        assert result.failure?
        assert_equal "baseline_digest_required", result.error.code
      end

      test "rejects a malformed baseline digest distinctly" do
        result = CreateDraft.call(
          organization: @organization,
          actor: @actor,
          fee_schedule_version: @version,
          assignment_type: "platform_grant",
          reason: "Malformed proof",
          effective_from: 1.day.from_now,
          baseline_resolution_digest: "z" * 64
        )

        assert result.failure?
        assert_equal "invalid_baseline_digest", result.error.code
      end
    end
  end
end
