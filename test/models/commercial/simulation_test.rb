# frozen_string_literal: true

require "test_helper"

module Commercial
  class SimulationTest < ActiveSupport::TestCase
    include Commercial::GovernanceTestHelpers

    setup do
      @version = create_simulatable_version(code: "simulation_model")
      @scenario_digest = "b" * 64
    end

    test "stores only digest-bound output evidence" do
      simulation = Simulation.new(
        fee_schedule_version: @version,
        definition_digest: @version.definition_digest,
        scenario_digest: @scenario_digest,
        normalized_outputs: { "buyer_fee_total" => 25 },
        warnings: [],
        passed: true,
        run_by: core_users(:super_admin),
        run_at: Time.current,
        idempotency_key_digest: "c" * 64,
        request_fingerprint: "d" * 64
      )

      assert_predicate simulation, :valid?
      assert_nil simulation.attributes["scenario"]
    end

    test "rejects a simulation whose assignment points at another version" do
      assignment = Commercial::Assignment.new(
        organization: organizations_organizations(:one),
        fee_schedule_version: create_simulatable_version(code: "simulation_other_version"),
        assignment_type: "platform_grant",
        status: "draft",
        reason: "Simulation mismatch",
        effective_from: 1.day.from_now,
        risk_level: "low",
        baseline_resolution_digest: "e" * 64,
        created_by: core_users(:super_admin)
      )
      simulation = Simulation.new(
        fee_schedule_version: @version,
        assignment:,
        definition_digest: @version.definition_digest,
        scenario_digest: @scenario_digest,
        normalized_outputs: {},
        warnings: [],
        passed: false,
        run_by: core_users(:super_admin),
        run_at: Time.current,
        idempotency_key_digest: "f" * 64,
        request_fingerprint: "0" * 64
      )

      assert_not simulation.valid?
      assert_match(/same fee schedule version/, simulation.errors[:assignment].join)
    end

    test "simulation evidence is immutable" do
      simulation = Simulation.create!(
        fee_schedule_version: @version,
        definition_digest: @version.definition_digest,
        scenario_digest: @scenario_digest,
        normalized_outputs: {},
        warnings: [],
        passed: true,
        run_by: core_users(:super_admin),
        run_at: Time.current,
        idempotency_key_digest: "1" * 64,
        request_fingerprint: "2" * 64
      )

      assert_raises(ActiveRecord::ReadOnlyRecord) { simulation.update!(passed: false) }
    end
  end
end
