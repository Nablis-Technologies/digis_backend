# frozen_string_literal: true

module Commercial
  module Defaults
    # Classifies a complete commercial result matrix before a platform default
    # can be scheduled. A worsening matrix must opt into explicit organizer
    # protection; it can never silently use the none policy.
    class ClassifyChange < Core::BaseService
      include Commercial::Governance::CommandSupport

      Classification = Data.define(:classification, :changes)
      ACCEPTANCE_POLICIES = %w[none notice_only explicit].freeze

      def initialize(baseline:, proposed:, acceptance_policy: nil)
        @baseline = baseline
        @proposed = proposed
        @acceptance_policy = acceptance_policy&.to_s
      end

      def call
        baseline_value = canonical_matrix(baseline)
        proposed_value = canonical_matrix(proposed)
        return failure(baseline_value) if baseline_value.is_a?(Core::Error)
        return failure(proposed_value) if proposed_value.is_a?(Core::Error)

        benefit = Commercial::Grants::ValidateBenefit.call(baseline:, proposed:)
        return failure(benefit.error) if benefit.failure? && invalid_comparison?(benefit.error)

        classification = if baseline_value == proposed_value
          "neutral"
        else
          benefit.success? ? "beneficial" : "worsening"
        end
        return failure(governance_error("none_worsening_forbidden", code: "none_worsening_forbidden")) if classification == "worsening" && acceptance_policy == "none"

        success(Classification.new(classification:, changes: []))
      end

      private

      attr_reader :baseline, :proposed, :acceptance_policy

      def canonical_matrix(matrix)
        return governance_error("simulation_invalid", code: "invalid_matrix") unless matrix.is_a?(Hash)

        canonicalize(matrix.deep_stringify_keys)
      end

      def invalid_comparison?(error)
        %w[invalid_matrix incomplete_comparison].include?(error.code)
      end
    end
  end
end
