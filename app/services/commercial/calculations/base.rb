# frozen_string_literal: true

require "bigdecimal"

module Commercial
  module Calculations
    # Shared integer-money calculation contract. Every strategy returns the
    # same scalar outcome, and percentage math is centralized here so every fee
    # type uses BigDecimal and half-up rounding consistently.
    class Base < Core::BaseService
      Outcome = Data.define(
        :amount_minor, :basis_minor, :fixed_amount_minor, :rate_bps, :minimum_minor, :maximum_minor,
        :tier_position, :tier_metric_type, :tier_metric_value, :tier_window_type, :tier_starts_at_value
      )

      INTEGER_ATTRIBUTES = %i[basis_minor fixed_amount_minor rate_bps minimum_minor maximum_minor].freeze

      def initialize(
        basis_minor: nil, fixed_amount_minor: nil, rate_bps: nil, minimum_minor: nil, maximum_minor: nil,
        tier: nil, **attributes
      )
        @basis_minor = basis_minor
        @fixed_amount_minor = fixed_amount_minor
        @rate_bps = rate_bps
        @minimum_minor = minimum_minor
        @maximum_minor = maximum_minor
        @tier = tier
        @unknown_attributes = attributes.keys
      end

      def call
        return failure(error("invalid_calculation")) if @unknown_attributes.any? || invalid_inputs?

        configuration_error = configuration_error_code
        return failure(error(configuration_error)) if configuration_error

        success(outcome(calculate_amount))
      end

      private

      attr_reader :basis_minor, :fixed_amount_minor, :rate_bps, :minimum_minor, :maximum_minor, :tier

      def calculate_amount
        raise NotImplementedError, I18n.t("commercial.resolution.errors.unsupported_calculation")
      end

      def configuration_error_code
        nil
      end

      def percentage_amount(basis = basis_minor, rate = rate_bps)
        ((basis * rate).to_d / 10_000).round(0, BigDecimal::ROUND_HALF_UP).to_i
      end

      def clamp(amount, minimum = minimum_minor, maximum = maximum_minor)
        amount = [ amount, minimum ].max if minimum
        amount = [ amount, maximum ].min if maximum
        amount
      end

      def outcome(amount)
        Outcome.new(
          amount_minor: amount,
          basis_minor:,
          fixed_amount_minor: effective_fixed_amount_minor,
          rate_bps: effective_rate_bps,
          minimum_minor: effective_minimum_minor,
          maximum_minor: effective_maximum_minor,
          tier_position: effective_tier&.position,
          tier_metric_type: effective_tier&.metric_type,
          tier_metric_value: effective_tier_metric_value,
          tier_window_type: effective_tier&.window_type,
          tier_starts_at_value: effective_tier&.starts_at_value
        )
      end

      def effective_fixed_amount_minor = fixed_amount_minor

      def effective_rate_bps = rate_bps

      def effective_minimum_minor = minimum_minor

      def effective_maximum_minor = maximum_minor

      def effective_tier = tier

      def effective_tier_metric_value = nil

      def invalid_inputs?
        INTEGER_ATTRIBUTES.any? do |attribute|
          value = instance_variable_get("@#{attribute}")
          value.present? && (!value.is_a?(Integer) || value.negative?)
        end || (rate_bps.present? && rate_bps > 10_000) ||
          (minimum_minor.present? && maximum_minor.present? && maximum_minor < minimum_minor)
      end

      def error(code)
        Core::BusinessError.new(
          I18n.t("commercial.resolution.errors.#{code}"),
          code:, status: :unprocessable_entity
        )
      end
    end
  end
end
