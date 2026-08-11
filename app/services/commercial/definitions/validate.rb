# frozen_string_literal: true

module Commercial
  module Definitions
    class Validate < Core::BaseService
      SCOPE_ATTRIBUTES = %i[
        event_product_id product_type sale_context provider payment_method sales_channel currency
      ].freeze

      def initialize(version:, currencies: [], target_event_id: nil)
        @version = version
        @currencies = Array(currencies).map { |currency| currency.to_s.strip.upcase }
        @target_event_id = target_event_id
      end

      def call
        @definition_version = load_version
        return invalid_definition unless @definition_version.valid?

        components = @definition_version.fee_components.to_a
        return error_result("definition_empty") if components.empty?

        @components = components
        scope_result = validate_scope_conflicts
        return scope_result if scope_result.failure?
        product_result = validate_exact_products
        return product_result if product_result.failure?
        shape_result = validate_component_shapes
        return shape_result if shape_result.failure?

        canonical = Commercial::Definitions::Canonicalize.call(version: @definition_version)
        return canonical if canonical.failure?
        return error_result("definition_digest_mismatch") unless digest_matches?(canonical.value.digest)

        success(canonical.value)
      end

      private

      attr_reader :version, :currencies, :target_event_id

      def load_version
        return version unless version.persisted?

        Commercial::FeeScheduleVersion
          .includes(:fee_schedule, fee_components: %i[fee_amounts fee_tiers event_product])
          .find(version.id)
      end

      def invalid_definition
        error_result("invalid_definition", errors: @definition_version.errors.to_hash)
      end

      def validate_scope_conflicts
        seen = {}
        @components.each do |component|
          key = [ component.component_type, *SCOPE_ATTRIBUTES.map { |attribute| component.public_send(attribute) } ]
          return error_result("ambiguous_component_scope") if seen.key?(key)

          seen[key] = true
        end

        success
      end

      def validate_exact_products
        @components.each do |component|
          next unless component.event_product_id.present?
          return error_result("exact_product_scope_requires_custom_schedule") unless custom_schedule?
          return error_result("exact_product_scope_event_mismatch") if target_event_id.blank?
          return error_result("exact_product_scope_event_mismatch") unless component.event_product.event_id.to_s == target_event_id.to_s
        end

        success
      end

      def validate_component_shapes
        @components.each do |component|
          result = validate_component_shape(component)
          return result if result.failure?
        end

        success
      end

      def validate_component_shape(component)
        case component.calculation_type
        when "explicit_zero"
          return error_result("invalid_component_shape") if component.fee_amounts.any? || component.fee_tiers.any?
        when "percentage"
          return error_result("invalid_component_shape") if component.fee_tiers.any?
          return error_result("invalid_component_shape") if component.fee_amounts.any? { |amount| amount.fixed_amount_minor.present? }
        when "fixed"
          return error_result("invalid_component_shape") if component.fee_tiers.any?
          return error_result("invalid_component_shape") if component.fee_amounts.any? && !currency_amounts_valid?(component)
        when "blended"
          return error_result("invalid_component_shape") if component.fee_tiers.any?
          return error_result("invalid_component_shape") if component.fee_amounts.any? && !currency_amounts_valid?(component)
        when "tiered"
          return error_result("invalid_component_shape") if component.fee_amounts.any?
          return validate_tiers(component)
        end

        validate_currency_coverage(component)
      end

      def currency_amounts_valid?(component)
        component.fee_amounts.all?(&:fixed_amount_minor)
      end

      def validate_currency_coverage(component)
        return success unless %w[fixed blended].include?(component.calculation_type)
        return error_result("missing_currency_coverage") if component.fee_amounts.empty?
        return success if currencies.empty?

        covered = component.fee_amounts.map(&:currency)
        return success if currencies.all? { |currency| covered.include?(currency) }

        error_result("missing_currency_coverage")
      end

      def validate_tiers(component)
        tiers = component.fee_tiers.sort_by(&:position)
        return error_result("tiers_invalid") if tiers.empty?
        return error_result("tiers_invalid") unless tiers.map(&:position) == (1..tiers.length).to_a
        return error_result("tiers_invalid") unless tiers.first.starts_at_value.zero?
        return error_result("tiers_invalid") unless same_tier_context?(tiers)
        return error_result("tiers_invalid") unless increasing_thresholds?(tiers)
        return error_result("tiers_invalid") unless tiers.all? { |tier| tier.rate_bps.present? || tier.fixed_amount_minor.present? }
        return error_result("missing_currency_coverage") unless gross_currency_coverage?(tiers)

        success
      end

      def same_tier_context?(tiers)
        tiers.map { |tier| [ tier.metric_type, tier.window_type ] }.uniq.one?
      end

      def increasing_thresholds?(tiers)
        tiers.each_cons(2).all? { |left, right| right.starts_at_value > left.starts_at_value }
      end

      def gross_currency_coverage?(tiers)
        return true unless tiers.first.metric_type == "accepted_gross"
        return true if currencies.empty?

        currencies.all? { |currency| tiers.any? { |tier| tier.currency == currency } }
      end

      def custom_schedule?
        @definition_version.fee_schedule.schedule_type == "custom"
      end

      def digest_matches?(digest)
        @definition_version.definition_digest == digest
      end

      def error_result(code, errors: nil)
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.definitions.errors.#{code}"),
            code: code,
            status: :unprocessable_entity,
            errors: errors
          )
        )
      end
    end
  end
end
