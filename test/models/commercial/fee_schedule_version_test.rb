# frozen_string_literal: true

require "test_helper"

module Commercial
  class FeeScheduleVersionTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    test "accepts the complete lifecycle state allowlist" do
      Commercial::FeeScheduleVersion::STATUSES.each_with_index do |status, index|
        schedule = create_schedule(code: "state_#{index}")
        attributes = { status: status }
        attributes[:approved_by] = core_users(:super_admin) if %w[approved scheduled active].include?(status)
        attributes[:approved_at] = Time.current if %w[approved scheduled active].include?(status)
        attributes[:activated_by] = core_users(:super_admin) if status == "active"
        attributes[:activated_at] = Time.current if status == "active"
        attributes[:terminated_by] = core_users(:super_admin) if status == "terminated"
        attributes[:terminated_at] = Time.current if status == "terminated"
        attributes[:effective_from] = 1.hour.from_now if %w[scheduled active].include?(status)

        version = build_version(schedule, attributes)

        assert_predicate version, :valid?, status
      end
    end

    test "requires a strictly ordered effective interval when both bounds exist" do
      schedule = create_schedule
      version = build_version(
        schedule,
        effective_from: 2.hours.from_now,
        effective_until: 1.hour.from_now
      )

      assert_not version.valid?
      assert_includes version.errors[:effective_until], "must be after effective_from"
    end

    test "requires a positive version number and same-schedule supersession" do
      schedule = create_schedule
      prior = create_version(schedule, version: 1)
      successor = build_version(schedule, version: 2, supersedes_version: prior)
      duplicate = build_version(schedule, version: 1)

      assert_predicate successor, :valid?
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:version], "has already been taken"

      other_schedule = create_schedule(code: "other_schedule")
      cross_schedule = build_version(
        other_schedule,
        version: 1,
        supersedes_version: prior
      )
      invalid_number = build_version(schedule, version: 0)

      assert_not cross_schedule.valid?
      assert_includes cross_schedule.errors[:supersedes_version], "must belong to the same fee schedule"
      assert_not invalid_number.valid?
      assert_includes invalid_number.errors[:version], "must be greater than 0"
    end

    test "does not allow definition edits after approval" do
      schedule = create_schedule
      version = create_version(
        schedule,
        effective_from: 1.hour.from_now,
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current
      )

      version.acceptance_policy = "explicit"
      version.definition_digest = "b" * 64

      assert_not version.valid?
      assert_includes version.errors[:base], I18n.t("commercial.definitions.errors.immutable")
    end

    test "database blocks bulk definition edits after approval" do
      schedule = create_schedule
      version = create_version(
        schedule,
        effective_from: 1.hour.from_now,
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Commercial::FeeScheduleVersion.where(id: version.id).update_all(definition_digest: "b" * 64)
      end
    end

    test "database prevents overlapping authoritative intervals in one schedule" do
      schedule = create_schedule
      start_time = 1.hour.from_now
      create_version(
        schedule,
        status: "scheduled",
        effective_from: start_time,
        effective_until: start_time + 2.hours
      )
      overlapping = build_version(
        schedule,
        version: 2,
        status: "scheduled",
        effective_from: start_time + 1.hour,
        effective_until: start_time + 3.hours
      )

      assert_raises(ActiveRecord::StatementInvalid) { overlapping.save! }
    end

    test "exposes version associations, scopes, and safe ransack fields" do
      assert_equal "Commercial::FeeSchedule", Commercial::FeeScheduleVersion.reflect_on_association(:fee_schedule).class_name
      assert_includes Commercial::FeeScheduleVersion.instance_methods, :authoritative?
      assert_includes Commercial::FeeScheduleVersion.ransackable_associations, "fee_components"
      assert_includes Commercial::FeeScheduleVersion.ransackable_attributes, "fee_schedule_id"
    end
  end
end
