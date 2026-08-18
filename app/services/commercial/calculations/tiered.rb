# frozen_string_literal: true

module Commercial
  module Calculations
    # Selects the prospective tier visible at quote time and applies that
    # tier's fixed/percentage terms. Accepted counters are read-only inputs;
    # this strategy never increments or mutates volume state.
    class Tiered < Base
      METRIC_TYPES = %w[accepted_paid_units accepted_gross].freeze

      def initialize(metric_type:, metric_value:, currency:, tiers:, **attributes)
        @metric_type = metric_type.to_s
        @metric_value = metric_value
        @currency = currency.to_s.upcase
        @tiers = tiers.to_a
        super(**attributes)
      end

      private

      attr_reader :metric_type, :metric_value, :currency, :tiers

      def calculate_amount
        @fixed_amount_minor = selected_tier.fixed_amount_minor
        @rate_bps = selected_tier.rate_bps
        @minimum_minor = selected_tier.minimum_minor
        @maximum_minor = selected_tier.maximum_minor

        clamp((@fixed_amount_minor || 0) + (@rate_bps ? percentage_amount(basis_minor, @rate_bps) : 0))
      end

      def configuration_error_code
        return "commercial_terms_unavailable" if tiers.empty? || !METRIC_TYPES.include?(metric_type)
        return "commercial_terms_unavailable" unless metric_value.is_a?(Integer) && metric_value >= 0
        return "commercial_terms_unavailable" if selected_tier.nil?
        return "basis_unavailable" if selected_tier.rate_bps.present? && basis_minor.nil?
        return "commercial_terms_unavailable" if selected_tier.rate_bps.blank? && selected_tier.fixed_amount_minor.blank?

        nil
      end

      def effective_fixed_amount_minor = selected_tier&.fixed_amount_minor

      def effective_rate_bps = selected_tier&.rate_bps

      def effective_minimum_minor = selected_tier&.minimum_minor

      def effective_maximum_minor = selected_tier&.maximum_minor

      def effective_tier = selected_tier

      def effective_tier_metric_value = metric_value

      def selected_tier
        # Tiers are prospective: the highest threshold already reached by the
        # committed counter applies to this quote and never rewrites history.
        @selected_tier ||= eligible_tiers.max_by do |candidate|
          [ candidate.starts_at_value, candidate.currency.present? ? 1 : 0, candidate.position ]
        end
      end

      def eligible_tiers
        tiers.select do |candidate|
          next false unless candidate.metric_type == metric_type
          next false unless candidate.starts_at_value <= metric_value

          candidate.currency.blank? || candidate.currency.to_s.upcase == currency
        end
      end
    end
  end
end
