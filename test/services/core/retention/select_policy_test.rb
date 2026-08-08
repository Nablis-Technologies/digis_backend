# frozen_string_literal: true

require "test_helper"

module Core
  module Retention
    class SelectPolicyTest < ActiveSupport::TestCase
      test "selects the latest effective active policy for a category and jurisdiction" do
        older = Core::DataRetentionPolicy.create!(
          category: "registration_free_text",
          jurisdiction_code: nil,
          version: 1,
          retention_days: 30,
          action: "erase_payload",
          status: "active",
          effective_at: 1.day.ago,
          created_by: core_users(:super_admin)
        )
        Core::DataRetentionPolicy.create!(
          category: "registration_free_text",
          jurisdiction_code: nil,
          version: 2,
          retention_days: 60,
          action: "erase_payload",
          status: "draft",
          effective_at: 1.hour.from_now,
          created_by: core_users(:super_admin)
        )

        result = Core::Retention::SelectPolicy.call(
          category: "registration_free_text",
          jurisdiction_code: nil,
          at: Time.current
        )

        assert_predicate result, :success?
        assert_equal older.id, result.value.id
      end

      test "prefers a jurisdiction-specific policy over a newer default" do
        default = Core::DataRetentionPolicy.create!(
          category: "registration_structured",
          version: 2,
          retention_days: 365,
          action: "erase_payload",
          status: "active",
          effective_at: 1.day.ago,
          created_by: core_users(:super_admin)
        )
        specific = Core::DataRetentionPolicy.create!(
          category: "registration_structured",
          jurisdiction_code: "ET",
          version: 1,
          retention_days: 30,
          action: "erase_payload",
          status: "active",
          effective_at: 1.day.ago,
          created_by: core_users(:super_admin)
        )

        result = Core::Retention::SelectPolicy.call(
          category: "registration_structured",
          jurisdiction_code: "et",
          at: Time.current
        )

        assert_predicate result, :success?
        assert_equal specific.id, result.value.id
        refute_equal default.id, result.value.id
      end
    end
  end
end
