# frozen_string_literal: true

module Commercial
  module Simulations
    # Runs the trusted commercial resolver against a draft definition and
    # stores immutable, digest-bound evidence for later approval. Draft terms
    # are injected into the resolver only for this command; they never enter
    # live candidate selection.
    class Run < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(version:, actor:, scenario:, idempotency_key:, assignment: nil)
        @version = version
        @actor = actor
        @scenario = scenario
        @idempotency_key = idempotency_key
        @assignment = assignment
      end

      def call
        return failure(unauthorized_error("commercial.simulate")) unless authorized?

        prepare_request!
        ActiveRecord::Base.transaction { run_locked }
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          governance_error("invalid_record", code: "invalid_record", errors: error.record.errors.to_hash)
        )
      end

      private

      attr_reader :version, :actor, :scenario, :idempotency_key, :assignment,
                  :normalized_scenario, :resolution_context, :scenario_digest,
                  :request_fingerprint, :idempotency_key_digest

      def authorized?
        actor&.has_permission?("commercial.simulate")
      end

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @idempotency_key_digest = idempotency_digest("simulation", idempotency_key)
        raw = scenario.to_h.deep_stringify_keys
        context_attributes = raw["resolution_context"] || raw
        @resolution_context = Commercial::Resolution::Context.new(context_attributes)
        @normalized_scenario = normalized_scenario_for(raw)
        @scenario_digest = fingerprint_for(normalized_scenario)
      end

      def normalized_scenario_for(raw)
        normalized = { "resolution_context" => canonicalize(resolution_context.to_h) }
        %w[baseline proposed].each do |key|
          normalized[key] = canonicalize(raw[key]) if raw.key?(key)
        end
        normalized
      end

      def run_locked
        locked_version = Commercial::FeeScheduleVersion.lock.find(version.id)
        @request_fingerprint = fingerprint_for(
          version_id: locked_version.id, assignment_id: assignment&.id,
          scenario_digest:, definition_digest: locked_version.definition_digest, actor_id: actor.id
        )
        existing = Simulation.lock.find_by(idempotency_key_digest:)
        return replay_result(existing) if existing

        evidence = build_evidence(locked_version)
        simulation = Simulation.create!(
          fee_schedule_version: locked_version,
          assignment: locked_assignment,
          definition_digest: locked_version.definition_digest,
          scenario_digest:,
          normalized_outputs: evidence.fetch(:outputs),
          warnings: evidence.fetch(:warnings),
          passed: evidence.fetch(:passed),
          run_by: actor,
          run_at: Time.current,
          idempotency_key_digest:,
          request_fingerprint:
        )
        if evidence[:passed] && locked_version.status == "draft"
          locked_version.update!(status: "simulated")
          record_version_simulated!(locked_version, simulation)
        end
        record_evidence!(simulation)
        return success(simulation) if evidence[:passed]

        failure(governance_error("simulation_invalid", code: "simulation_invalid"))
      end

      def locked_assignment
        return unless assignment

        Commercial::Assignment.lock.find(assignment.id)
      end

      def replay_result(existing)
        return success(existing) if existing.request_fingerprint == request_fingerprint

        failure(governance_error("idempotency_conflict", code: "idempotency_conflict"))
      end

      def build_evidence(locked_version)
        validation = Commercial::Definitions::Validate.call(
          version: locked_version,
          currencies: [ resolution_context.currency ],
          target_event_id: resolution_context.event_id
        )
        return invalid_evidence(validation.error.code) if validation.failure?

        resolution = Commercial::ResolveCharges.call(
          context: resolution_context, only_version: locked_version
        )
        return invalid_evidence(resolution.error.code) if resolution.failure?

        outputs = resolution.value.to_h.deep_stringify_keys
        comparison = comparison_evidence
        return invalid_evidence(comparison.error.code) if comparison&.failure?

        outputs.merge!(comparison.value) if comparison
        { passed: true, outputs:, warnings: [] }
      end

      def comparison_evidence
        raw = scenario.to_h.deep_stringify_keys
        return unless raw.key?("baseline") || raw.key?("proposed")

        Commercial::Grants::ValidateBenefit.call(
          baseline: raw["baseline"], proposed: raw["proposed"]
        ).then do |result|
          result.success? ? Core::BaseService::Result.success(result.value.deep_stringify_keys) : result
        end
      end

      def invalid_evidence(code)
        {
          passed: false,
          outputs: { "error_code" => code.to_s },
          warnings: [ { "code" => code.to_s } ]
        }
      end

      def record_evidence!(simulation)
        record_transition!(
          target: simulation, actor:, audit_key: audit_key, action: "commercial.simulation.ran",
          audited_changes: { "passed" => simulation.passed, "definition_digest" => simulation.definition_digest },
          metadata: { "request_fingerprint" => request_fingerprint, "scenario_digest" => scenario_digest },
          topic: "commercial", event_type: "commercial.simulation.ran",
          payload: {
            simulation_id: simulation.id, fee_schedule_version_id: simulation.fee_schedule_version_id,
            assignment_id: simulation.assignment_id, definition_digest: simulation.definition_digest,
            scenario_digest: simulation.scenario_digest, passed: simulation.passed
          }
        )
      end

      def record_version_simulated!(locked_version, simulation)
        transition_key = "commercial-version-simulated-#{simulation.id}"
        record_transition!(
          target: locked_version, actor:, audit_key: transition_key, action: "commercial.version.simulated",
          audited_changes: { "status" => [ "draft", "simulated" ] },
          metadata: { "simulation_id" => simulation.id, "request_fingerprint" => request_fingerprint },
          topic: "commercial", event_type: "commercial.version.simulated",
          payload: { fee_schedule_version_id: locked_version.id, simulation_id: simulation.id, status: locked_version.status },
          outbox_key: transition_key
        )
      end

      def audit_key
        "commercial-simulation-#{idempotency_key_digest}"
      end
    end
  end
end
