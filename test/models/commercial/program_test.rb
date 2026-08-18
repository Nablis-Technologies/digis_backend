# frozen_string_literal: true

require "test_helper"

module Commercial
  class ProgramTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    test "belongs to exactly one program fee schedule" do
      schedule = create_schedule(code: "launch_program", schedule_type: "program")
      program = Program.new(
        fee_schedule: schedule,
        program_type: "first_monetized_event",
        enrollment_mode: "automatic",
        starts_at: 1.day.from_now,
        ends_at: 2.days.from_now,
        active: true
      )

      assert_predicate program, :valid?
      assert_equal schedule, program.fee_schedule
      assert_equal "program", program.fee_schedule.schedule_type
    end

    test "requires a program schedule and an allowlisted strategy" do
      default_schedule = create_schedule(code: "default_program_test", schedule_type: "platform_default")
      invalid_schedule_program = Program.new(
        fee_schedule: default_schedule,
        program_type: "first_monetized_event",
        enrollment_mode: "manual",
        active: false
      )
      unknown_type_program = Program.new(
        fee_schedule: create_schedule(code: "strategy_program", schedule_type: "program"),
        program_type: "arbitrary_expression",
        enrollment_mode: "manual",
        active: false
      )

      assert_not invalid_schedule_program.valid?
      assert_includes invalid_schedule_program.errors[:fee_schedule], "must have schedule_type program"
      assert_not unknown_type_program.valid?
      assert_includes unknown_type_program.errors[:program_type], "is not included in the list"
      assert_equal :first_monetized_event, Program::STRATEGY_REGISTRY.fetch("first_monetized_event")
      refute_includes Program.column_names, "conditions"
    end

    test "constrains enrollment, interval, and use-limit fields" do
      schedule = create_schedule(code: "bounded_program", schedule_type: "program")
      program = Program.new(
        fee_schedule: schedule,
        program_type: "charity",
        enrollment_mode: "automatic",
        starts_at: 2.days.from_now,
        ends_at: 1.day.from_now,
        per_organization_use_limit: 0,
        active: true
      )

      assert_not program.valid?
      assert_includes program.errors[:ends_at], "must be after starts_at"
      assert_includes program.errors[:per_organization_use_limit], "must be greater than 0"
    end

    test "exposes active window and safe ransack contracts" do
      assert_equal "Commercial::FeeSchedule", Program.reflect_on_association(:fee_schedule).class_name
      assert_includes Program.ransackable_attributes, "fee_schedule_id"
      assert_includes Program.ransackable_associations, "assignments"
      assert_includes Program.ransackable_associations, "entitlements"
      assert_includes Program.ransackable_associations, "fee_schedule"
    end
  end
end
