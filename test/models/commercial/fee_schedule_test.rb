# frozen_string_literal: true

require "test_helper"

module Commercial
  class FeeScheduleTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    test "accepts only the supported schedule types" do
      Commercial::FeeSchedule::SCHEDULE_TYPES.each do |schedule_type|
        schedule = build_schedule(schedule_type: schedule_type)

        assert_predicate schedule, :valid?, schedule_type
      end

      schedule = build_schedule(schedule_type: "temporary")

      assert_not schedule.valid?
      assert_includes schedule.errors[:schedule_type], "is not included in the list"
    end

    test "normalizes and uniquely identifies a stable code" do
      schedule = create_schedule(code: "Platform_Default")
      duplicate = build_schedule(code: "platform_default")

      assert_equal "platform_default", schedule.code
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:code], "has already been taken"
    end

    test "exposes explicit associations and safe ransack fields" do
      assert_equal "Core::User", Commercial::FeeSchedule.reflect_on_association(:created_by).class_name
      assert_includes Commercial::FeeSchedule.ransackable_attributes, "code"
      assert_includes Commercial::FeeSchedule.ransackable_associations, "fee_schedule_versions"
    end
  end
end
