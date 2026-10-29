# frozen_string_literal: true

require "test_helper"
require "support/idempotency_assertions"

module Commercial
  module Simulations
    class RunTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_simulatable_version(code: "simulation_run")
        @scenario = { resolution_context: simulation_scenario }
      end

      test "binds passing evidence to the current definition and normalized scenario" do
        result = Run.call(
          version: @version, actor: core_users(:super_admin), scenario: @scenario,
          idempotency_key: "simulation-run-1"
        )

        assert result.success?, result.error&.message
        simulation = result.value
        assert simulation.passed
        assert_equal @version.definition_digest, simulation.definition_digest
        assert_equal 64, simulation.scenario_digest.length
        assert_equal @version.id, simulation.fee_schedule_version_id
        assert simulation.normalized_outputs.key?("buyer_fee_total")
      end

      test "editing a draft makes the previous simulation stale" do
        result = run_passing_simulation(version: @version, idempotency_key: "simulation-run-2", scenario: @scenario)
        assert result.success?, result.error&.message

        @version.reload.fee_components.first.update!(rate_bps: 800)
        @version.reload
        sync_definition_digest(@version)

        assert_empty Simulation.current_for(@version, @version.definition_digest).passing
      end

      test "replays are idempotent and conflicting request fingerprints fail" do
        subject = -> do
          Run.call(
            version: @version, actor: core_users(:super_admin), scenario: @scenario,
            idempotency_key: "simulation-run-3"
          )
        end

        assert_idempotent(subject, counter: -> { Simulation.count })
        assert_equal 1, Core::AuditLog.where(action: "commercial.simulation.ran").count

        conflict = Run.call(
          version: @version, actor: core_users(:super_admin),
          scenario: { resolution_context: simulation_scenario(quoted_at: 1.hour.from_now) },
          idempotency_key: "simulation-run-3"
        )
        assert conflict.failure?
        assert_equal "idempotency_conflict", conflict.error.code
      end

      test "accepts ISO8601 string quoted_at or defaults when omitted" do
        string_result = Run.call(
          version: @version, actor: core_users(:super_admin),
          scenario: { resolution_context: simulation_scenario.merge(quoted_at: Time.current.iso8601) },
          idempotency_key: "simulation-run-string-time"
        )
        assert string_result.success?, string_result.error&.message

        omitted_scenario = simulation_scenario
        omitted_scenario.delete(:quoted_at)
        omitted_result = Run.call(
          version: @version, actor: core_users(:super_admin),
          scenario: { resolution_context: omitted_scenario },
          idempotency_key: "simulation-run-omitted-time"
        )
        assert omitted_result.success?, omitted_result.error&.message
      end

      test "omitted quoted_at is stable across idempotent retries" do
        omitted_scenario = simulation_scenario
        omitted_scenario.delete(:quoted_at)
        subject = lambda do
          Run.call(
            version: @version, actor: core_users(:super_admin),
            scenario: { resolution_context: omitted_scenario },
            idempotency_key: "simulation-run-omitted-stable"
          )
        end

        assert_idempotent(subject, counter: -> { Simulation.count })
      end
    end
  end
end
