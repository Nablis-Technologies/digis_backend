# frozen_string_literal: true

require "test_helper"

module Commercial
  module Defaults
    class ClassifyChangeTest < ActiveSupport::TestCase
      test "classifies equal, beneficial, and worsening matrices" do
        baseline = matrix(rate_bps: 750)

        neutral = ClassifyChange.call(baseline:, proposed: matrix(rate_bps: 750))
        beneficial = ClassifyChange.call(baseline:, proposed: matrix(rate_bps: 500))
        worsening = ClassifyChange.call(baseline:, proposed: matrix(rate_bps: 1_000))

        assert_equal "neutral", neutral.value.classification
        assert_equal "beneficial", beneficial.value.classification
        assert_equal "worsening", worsening.value.classification
      end

      test "rejects worsening changes configured with none" do
        result = ClassifyChange.call(
          baseline: matrix(rate_bps: 750), proposed: matrix(rate_bps: 1_000), acceptance_policy: "none"
        )

        assert result.failure?
        assert_equal "none_worsening_forbidden", result.error.code
      end

      private

      def matrix(rate_bps:)
        {
          "online:ETB" => {
            "platform_commission" => {
              "rate_bps" => rate_bps, "charged_to" => "organizer", "funded_by" => "organizer"
            }
          }
        }
      end
    end
  end
end
