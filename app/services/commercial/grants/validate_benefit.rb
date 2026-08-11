# frozen_string_literal: true

module Commercial
  module Grants
    # Proves a platform grant never worsens an organizer's full result matrix.
    class ValidateBenefit < Core::BaseService
      NUMERIC_FIELDS = %w[rate_bps fixed_amount_minor minimum_minor maximum_minor subsidy_minor].freeze
      ALLOWED_FIELDS = (NUMERIC_FIELDS + %w[charged_to funded_by benefit_expires_at]).freeze
      PAYERS = %w[buyer organizer].freeze
      FUNDERS = %w[buyer organizer platform].freeze

      def initialize(baseline:, proposed:)
        @baseline = baseline
        @proposed = proposed
      end

      def call
        baseline_matrix, baseline_error = normalize_matrix(baseline)
        return failure(baseline_error) if baseline_error

        proposed_matrix, proposed_error = normalize_matrix(proposed)
        return failure(proposed_error) if proposed_error

        comparison_error = compare_matrix(baseline_matrix, proposed_matrix)
        return failure(comparison_error) if comparison_error

        success(classification: "beneficial", changes: [])
      end

      private

      attr_reader :baseline, :proposed

      def normalize_matrix(matrix)
        return [ nil, error_for(:invalid_matrix, "invalid_matrix") ] unless matrix.is_a?(Hash)
        return [ {}, nil ] if matrix.empty?

        normalized = {}
        matrix.each do |context, components|
          return [ nil, error_for(:invalid_matrix, "invalid_matrix") ] unless components.is_a?(Hash)

          normalized_context = context.to_s
          return [ nil, error_for(:invalid_matrix, "invalid_matrix") ] if normalized.key?(normalized_context)

          normalized_components = {}
          components.each do |component_type, attributes|
            normalized_component = component_type.to_s
            return [ nil, error_for(:invalid_matrix, "invalid_matrix") ] if normalized_components.key?(normalized_component)
            return [ nil, error_for(:invalid_matrix, "invalid_matrix") ] unless attributes.is_a?(Hash)

            row = attributes.to_h.transform_keys(&:to_s)
            return [ nil, error_for(:invalid_matrix, "invalid_matrix") ] unless (row.keys - ALLOWED_FIELDS).empty?

            normalized_components[normalized_component] = normalize_row(row)
            return [ nil, error_for(:invalid_matrix, "invalid_matrix") ] if normalized_components[normalized_component].nil?
          end
          normalized[normalized_context] = normalized_components
        end

        [ normalized, nil ]
      end

      def normalize_row(row)
        normalized = row.slice(*ALLOWED_FIELDS)
        NUMERIC_FIELDS.each do |field|
          value = normalized[field]
          next if value.nil?
          return nil unless value.respond_to?(:to_i) && value.to_s.match?(/\A\d+\z/)

          normalized[field] = value.to_i
        end
        return nil if normalized["charged_to"].present? && !normalized["charged_to"].in?(PAYERS)
        return nil if normalized["funded_by"].present? && !normalized["funded_by"].in?(FUNDERS)

        if normalized["benefit_expires_at"].present?
          normalized["benefit_expires_at"] = parse_time(normalized["benefit_expires_at"])
          return nil if normalized["benefit_expires_at"].nil?
        end

        normalized
      end

      def compare_matrix(baseline_matrix, proposed_matrix)
        return error_for(:incomplete_comparison, "incomplete_comparison") if baseline_matrix.empty? || proposed_matrix.empty?
        return error_for(:incomplete_comparison, "incomplete_comparison") unless baseline_matrix.keys.sort == proposed_matrix.keys.sort

        baseline_matrix.each do |context, baseline_components|
          proposed_components = proposed_matrix.fetch(context)
          missing = baseline_components.keys - proposed_components.keys
          missing.each do |component_type|
            return error_for(:subsidy_removed, "subsidy_removed") if baseline_components.fetch(component_type)["subsidy_minor"].to_i.positive?
          end

          proposed_components.each do |component_type, proposed_row|
            baseline_row = baseline_components[component_type]
            if baseline_row.nil?
              return error_for(:organizer_funded_component_added, "organizer_funded_component_added") if proposed_row["funded_by"] == "organizer"

              next
            end

            error = compare_component(baseline_row, proposed_row)
            return error if error
          end
        end

        nil
      end

      def compare_component(baseline_row, proposed_row)
        return error_for(:rate_increase, "rate_increase") if increased?(baseline_row, proposed_row, "rate_bps")
        return error_for(:rate_increase, "rate_increase") if increased?(baseline_row, proposed_row, "fixed_amount_minor")
        return error_for(:rate_increase, "rate_increase") if increased?(baseline_row, proposed_row, "minimum_minor")
        return error_for(:cap_removed, "cap_removed") if cap_worsened?(baseline_row, proposed_row)
        return error_for(:payer_switch, "payer_switch") if payer_worsened?(baseline_row, proposed_row)
        return error_for(:benefit_shortened, "benefit_shortened") if benefit_shortened?(baseline_row, proposed_row)
        return error_for(:subsidy_removed, "subsidy_removed") if subsidy_reduced?(baseline_row, proposed_row)
        return error_for(:organizer_funded_component_added, "organizer_funded_component_added") if funding_worsened?(baseline_row, proposed_row)

        nil
      end

      def increased?(baseline_row, proposed_row, field)
        proposed_value = proposed_row[field]
        return false if proposed_value.nil?

        proposed_value > baseline_row[field].to_i
      end

      def cap_worsened?(baseline_row, proposed_row)
        baseline_cap = baseline_row["maximum_minor"]
        proposed_cap = proposed_row["maximum_minor"]
        return false if baseline_cap.nil?
        return true if proposed_cap.nil?

        proposed_cap > baseline_cap
      end

      def payer_worsened?(baseline_row, proposed_row)
        baseline_row["charged_to"] == "buyer" && proposed_row["charged_to"] == "organizer"
      end

      def benefit_shortened?(baseline_row, proposed_row)
        baseline_expiry = baseline_row["benefit_expires_at"]
        proposed_expiry = proposed_row["benefit_expires_at"]
        return false if baseline_expiry == proposed_expiry
        return true if baseline_expiry.nil? && proposed_expiry.present?
        return false if proposed_expiry.nil?

        proposed_expiry < baseline_expiry
      end

      def subsidy_reduced?(baseline_row, proposed_row)
        baseline_subsidy = baseline_row["subsidy_minor"].to_i
        baseline_subsidy.positive? && proposed_row["subsidy_minor"].to_i < baseline_subsidy
      end

      def funding_worsened?(baseline_row, proposed_row)
        baseline_row["funded_by"] != "organizer" && proposed_row["funded_by"] == "organizer"
      end

      def parse_time(value)
        return value.to_time if value.respond_to?(:to_time)

        Time.iso8601(value.to_s)
      rescue ArgumentError, NoMethodError
        nil
      end

      def error_for(key, code)
        Core::BusinessError.new(
          I18n.t("commercial.grants.errors.#{key}"),
          code:, status: :unprocessable_entity
        )
      end
    end
  end
end
