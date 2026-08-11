# frozen_string_literal: true

require "test_helper"

module Commercial
  module Versions
    class ScheduleTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(code: "version_schedule", effective_from: 2.days.from_now)
        run_passing_simulation(version: @version, idempotency_key: "version-schedule-sim")
        Submit.call(version: @version, actor: core_users(:super_admin), idempotency_key: "version-schedule-submit")
        Approve.call(version: @version, actor: core_users(:super_admin), reason: "Review", idempotency_key: "version-schedule-approve")
      end

      test "requires an effective time and schedules an approved version" do
        result = Schedule.call(version: @version, actor: core_users(:super_admin), idempotency_key: "version-schedule-1")

        assert result.success?, result.error&.message
        assert_equal "scheduled", result.value.status
      end

      test "does not allow a worsening default to use none" do
        @version.simulations.create!(
          definition_digest: @version.definition_digest,
          scenario_digest: "8" * 64,
          normalized_outputs: { "classification" => "worsening" },
          warnings: [], passed: true, run_by: core_users(:super_admin), run_at: Time.current,
          idempotency_key_digest: "9" * 64, request_fingerprint: "a" * 64
        )
        @version.update_column(:status, "approved")

        result = Schedule.call(version: @version, actor: core_users(:super_admin), idempotency_key: "version-schedule-2")

        assert result.failure?
        assert_equal "none_worsening_forbidden", result.error.code
      end
    end
  end
end
