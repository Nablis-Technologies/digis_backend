# frozen_string_literal: true

require "test_helper"

module Commercial
  module Grants
    class ValidateBenefitTest < ActiveSupport::TestCase
      test "accepts a complete non-worsening matrix" do
        result = ValidateBenefit.call(baseline: baseline_matrix, proposed: beneficial_matrix)

        assert result.success?, result.error&.message
        assert_equal "beneficial", result.value[:classification]
      end

      test "detects rate increases" do
        assert_failure_for(
          baseline_matrix,
          beneficial_matrix.deep_merge(
            "online:ETB" => { "platform_commission" => { "rate_bps" => 800 } }
          ),
          "rate_increase"
        )
      end

      test "detects removed caps" do
        proposed = beneficial_matrix.deep_dup
        proposed["online:ETB"]["platform_commission"].delete("maximum_minor")

        assert_failure_for(baseline_matrix, proposed, "cap_removed")
      end

      test "detects a buyer-to-organizer payer switch" do
        baseline = baseline_matrix.deep_merge(
          "online:ETB" => {
            "buyer_service_fee" => {
              "rate_bps" => 250, "charged_to" => "buyer", "funded_by" => "buyer"
            }
          }
        )
        proposed = beneficial_matrix.deep_merge(
          "online:ETB" => {
            "buyer_service_fee" => {
              "rate_bps" => 250, "charged_to" => "organizer", "funded_by" => "organizer"
            }
          }
        )

        assert_failure_for(baseline, proposed, "payer_switch")
      end

      test "detects shorter benefits" do
        proposed = beneficial_matrix.deep_merge(
          "online:ETB" => {
            "platform_commission" => { "benefit_expires_at" => "2026-06-30T00:00:00Z" }
          }
        )

        assert_failure_for(baseline_matrix, proposed, "benefit_shortened")
      end

      test "detects a finite replacement for an unbounded benefit" do
        baseline = baseline_matrix.deep_dup
        baseline["online:ETB"]["platform_commission"].delete("benefit_expires_at")

        assert_failure_for(baseline, beneficial_matrix, "benefit_shortened")
      end

      test "detects removed subsidies" do
        proposed = beneficial_matrix.deep_dup
        proposed["online:ETB"]["platform_subsidy"]["subsidy_minor"] = 0

        assert_failure_for(baseline_matrix, proposed, "subsidy_removed")
      end

      test "detects new organizer-funded components" do
        proposed = beneficial_matrix.deep_dup
        proposed["online:ETB"]["processing_cost_recovery"] = {
          "rate_bps" => 100, "charged_to" => "organizer", "funded_by" => "organizer"
        }

        assert_failure_for(baseline_matrix, proposed, "organizer_funded_component_added")
      end

      test "fails closed when a context or component comparison is missing" do
        proposed = beneficial_matrix.deep_dup
        proposed.delete("online:ETB")

        assert_failure_for(baseline_matrix, proposed, "incomplete_comparison")
      end

      private

      def assert_failure_for(baseline, proposed, code)
        result = ValidateBenefit.call(baseline:, proposed:)

        assert result.failure?, result.error&.message
        assert_equal code, result.error.code
      end

      def baseline_matrix
        {
          "online:ETB" => {
            "platform_commission" => {
              "rate_bps" => 750,
              "charged_to" => "organizer",
              "funded_by" => "organizer",
              "maximum_minor" => 10_000,
              "benefit_expires_at" => "2026-12-31T00:00:00Z"
            },
            "platform_subsidy" => {
              "subsidy_minor" => 100,
              "charged_to" => "organizer",
              "funded_by" => "platform"
            }
          }
        }
      end

      def beneficial_matrix
        {
          "online:ETB" => {
            "platform_commission" => {
              "rate_bps" => 500,
              "charged_to" => "organizer",
              "funded_by" => "organizer",
              "maximum_minor" => 5_000,
              "benefit_expires_at" => "2027-12-31T00:00:00Z"
            },
            "platform_subsidy" => {
              "subsidy_minor" => 200,
              "charged_to" => "organizer",
              "funded_by" => "platform"
            }
          }
        }
      end
    end
  end
end
