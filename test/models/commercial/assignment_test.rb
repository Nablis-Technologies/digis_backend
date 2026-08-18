# frozen_string_literal: true

require "test_helper"

module Commercial
  class AssignmentTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    setup do
      @organization = organizations_organizations(:one)
      @other_organization = organizations_organizations(:two)
      @event = events_events(:draft_concert)
      @schedule = create_schedule(code: "assignment_schedule")
      @version = create_version(@schedule)
      @program_schedule = create_schedule(code: "assignment_program", schedule_type: "program")
      @program = Commercial::Program.create!(
        fee_schedule: @program_schedule,
        program_type: "partnership",
        enrollment_mode: "manual",
        active: true
      )
      @program_version = create_version(@program_schedule, version: 1)
    end

    test "supports organization-wide and event-specific targets only" do
      organization_assignment = build_assignment
      event_assignment = build_assignment(event: @event)

      assert_predicate organization_assignment, :valid?
      assert_predicate event_assignment, :valid?
      assert_nil organization_assignment.event
      assert_equal @event, event_assignment.event
      refute_includes Assignment.column_names, "target_type"
      refute_includes Assignment.column_names, "target_id"
    end

    test "requires an event target to belong to the assignment organization" do
      assignment = build_assignment(event: @event, organization: @other_organization)

      assert_not assignment.valid?
      assert_includes assignment.errors[:event], "must belong to the organization"
    end

    test "constrains types, statuses, risk levels, and effective intervals" do
      assignment = build_assignment(
        assignment_type: "unknown",
        status: "unknown",
        risk_level: "unknown",
        effective_from: 2.days.from_now,
        effective_until: 1.day.from_now
      )

      assert_not assignment.valid?
      assert_includes assignment.errors[:assignment_type], "is not included in the list"
      assert_includes assignment.errors[:status], "is not included in the list"
      assert_includes assignment.errors[:risk_level], "is not included in the list"
      assert_includes assignment.errors[:effective_until], "must be after effective_from"
    end

    test "requires a baseline digest for platform grants but no acceptance" do
      grant = build_assignment(
        assignment_type: "platform_grant",
        baseline_resolution_digest: nil,
        legal_acceptance: nil
      )
      valid_grant = build_assignment(
        assignment_type: "platform_grant",
        baseline_resolution_digest: "b" * 64,
        legal_acceptance: nil
      )

      assert_not grant.valid?
      assert_includes grant.errors[:baseline_resolution_digest], "is required for a platform grant"
      assert_predicate valid_grant, :valid?
    end

    test "mutual agreements need acceptance evidence before scheduling or activation" do
      assignment = build_assignment(
        assignment_type: "mutual_agreement",
        status: "scheduled",
        external_reference: nil,
        legal_acceptance: nil
      )

      assert_not assignment.valid?
      assert_includes assignment.errors[:base], "requires in-app acceptance or an external reference"
    end

    test "program assignments link the assigned version to the program schedule" do
      version = @program_version
      assignment = build_assignment(
        assignment_type: "program",
        fee_schedule_version: version,
        program: @program
      )
      mismatch = build_assignment(
        assignment_type: "program",
        fee_schedule_version: @version,
        program: @program
      )

      assert_predicate assignment, :valid?
      assert_not mismatch.valid?
      assert_includes mismatch.errors[:fee_schedule_version], "must belong to the assigned program"
    end

    test "exposes associations and safe ransack contracts" do
      assert_equal "Organizations::Organization", Assignment.reflect_on_association(:organization).class_name
      assert_equal "Events::Event", Assignment.reflect_on_association(:event).class_name
      assert_includes Assignment.ransackable_attributes, "organization_id"
      assert_includes Assignment.ransackable_attributes, "status"
      assert_includes Assignment.ransackable_associations, "fee_schedule_version"
      assert_includes Assignment.ransackable_associations, "program"
    end

    private

    def build_assignment(attributes = {})
      Assignment.new(
        {
          organization: @organization,
          fee_schedule_version: @version,
          assignment_type: "platform_grant",
          status: "draft",
          reason: "Task 3 test assignment",
          effective_from: 1.day.from_now,
          risk_level: "low",
          baseline_resolution_digest: "a" * 64,
          created_by: core_users(:super_admin)
        }.merge(attributes)
      )
    end
  end
end
