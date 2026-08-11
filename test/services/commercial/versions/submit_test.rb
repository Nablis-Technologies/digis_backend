# frozen_string_literal: true

require "test_helper"

module Commercial
  module Versions
    class SubmitTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(code: "version_submit", effective_from: 2.days.from_now)
      end

      test "requires a passing simulation for the current definition" do
        result = Submit.call(version: @version, actor: core_users(:super_admin), idempotency_key: "version-submit-1")

        assert result.failure?
        assert_equal "simulation_required", result.error.code
      end

      test "moves the simulated version into approval and is replay-safe" do
        simulation = run_passing_simulation(version: @version, idempotency_key: "version-submit-sim")
        assert simulation.success?, simulation.error&.message

        result = Submit.call(version: @version, actor: core_users(:super_admin), idempotency_key: "version-submit-2")
        assert result.success?, result.error&.message
        assert_equal "pending_approval", result.value.status
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.version.submitted").count

        replay = Submit.call(version: @version, actor: core_users(:super_admin), idempotency_key: "version-submit-2")
        assert replay.success?, replay.error&.message
        assert_equal 1, Core::AuditLog.where(action: "commercial.version.submitted").count
      end
    end
  end
end
