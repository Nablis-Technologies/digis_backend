# frozen_string_literal: true

require "test_helper"

module Commercial
  module Versions
    class ActivateTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      test "atomically supersedes the previous active version and publishes once" do
        schedule = create_schedule(code: "version_activate")
        previous = create_version(schedule, version: 1, effective_from: 3.days.ago)
        populate_simulatable_version(previous)
        previous.update!(status: "active", activated_by: core_users(:super_admin), activated_at: 3.days.ago)

        replacement = create_version(schedule, version: 2, effective_from: 1.hour.ago, supersedes_version: previous)
        populate_simulatable_version(replacement)
        run_passing_simulation(version: replacement, idempotency_key: "version-activate-sim")
        Submit.call(version: replacement, actor: core_users(:super_admin), idempotency_key: "version-activate-submit")
        Approve.call(version: replacement, actor: core_users(:super_admin), reason: "Review", idempotency_key: "version-activate-approve")
        Schedule.call(version: replacement, actor: core_users(:super_admin), idempotency_key: "version-activate-schedule")

        result = Activate.call(version: replacement, actor: core_users(:super_admin), idempotency_key: "version-activate-1")

        assert result.success?, result.error&.message
        assert_equal "active", replacement.reload.status
        assert_equal "superseded", previous.reload.status
        assert_equal 1, Core::AuditLog.where(action: "commercial.version.activated").count
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.version.activated").count
      end
    end
  end
end
