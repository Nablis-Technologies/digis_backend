# frozen_string_literal: true

require "digest"
require "json"

module Commercial
  # Resolves and calculates provider-independent commercial charges without
  # writing orders or calling a gateway. Orders owns the transaction that later
  # snapshots this frozen result as immutable adjustment evidence.
  class ResolveCharges < Core::BaseService
    PRIMARY_COMPONENT_TYPES = %w[
      platform_commission buyer_service_fee processing_cost_recovery
    ].freeze
    RESALE_COMPONENT_TYPES = %w[
      buyer_service_fee processing_cost_recovery resale_platform_fee
    ].freeze
    OPTIONAL_COMPONENT_TYPES = %w[platform_subsidy].freeze

    CALCULATION_REGISTRY = {
      "explicit_zero" => Commercial::Calculations::ExplicitZero,
      "percentage" => Commercial::Calculations::Percentage,
      "fixed" => Commercial::Calculations::Fixed,
      "blended" => Commercial::Calculations::Blended,
      "tiered" => Commercial::Calculations::Tiered
    }.freeze

    def initialize(context: nil, only_version: nil, **attributes)
      @only_version = only_version
      @context = if context.is_a?(Commercial::Resolution::Context)
        context
      elsif context.respond_to?(:to_h)
        Commercial::Resolution::Context.new(context.to_h.merge(attributes))
      else
        Commercial::Resolution::Context.new(attributes)
      end
    rescue ArgumentError => error
      @context_error = error
    end

    def call
      return failure(error("invalid_context")) if @context_error || invalid_context?

      candidates_result = Commercial::Resolution::CandidateQuery.call(context:, only_version:)
      return failure(candidates_result.error) if candidates_result.failure?

      selections = select_components(candidates_result.value)
      return failure(selections.error) if selections.failure?

      result = selections.value.map { |selection| calculate_component(selection) }
      failure_result = result.find(&:failure?)
      return failure(failure_result.error) if failure_result

      component_results = result.map(&:value)
      success(build_charge_result(component_results))
    end

    private

    attr_reader :context, :only_version

    def required_component_types
      context.sale_context == "resale" ? RESALE_COMPONENT_TYPES : PRIMARY_COMPONENT_TYPES
    end

    def select_components(candidates)
      selections = required_component_types.map do |component_type|
        result = Commercial::Resolution::SelectComponent.call(
          component_type:, context:, candidates:
        )
        return result if result.failure?

        result.value
      end

      OPTIONAL_COMPONENT_TYPES.each do |component_type|
        # An absent optional subsidy is different from a missing required
        # charge. If present, it is returned as its own negative adjustment.
        result = Commercial::Resolution::SelectComponent.call(
          component_type:, context:, candidates:
        )
        if result.success?
          selections << result.value
          next
        end

        return result unless result.error.code == "commercial_terms_unavailable"
      end

      Core::BaseService::Result.success(selections)
    end

    def calculate_component(selection)
      component = selection.component
      payer_result = resolve_payer(component)
      return payer_result if payer_result.failure?

      basis_result = resolve_basis(component)
      return basis_result if basis_result.failure?

      amount = amount_for(component)
      return failure(error("commercial_terms_unavailable")) if component.fee_amounts.any? && amount.blank?

      calculator = calculator_for(component)
      return failure(error("unsupported_calculation")) unless calculator

      calculation_attributes = {
        basis_minor: basis_result.value,
        fixed_amount_minor: amount&.fixed_amount_minor,
        minimum_minor: amount&.minimum_minor,
        maximum_minor: amount&.maximum_minor,
        rate_bps: component.rate_bps
      }
      calculation_attributes.merge!(
        tiers: component.fee_tiers.to_a,
        metric_type: tier_metric_type(component),
        metric_value: tier_metric_value(component),
        currency: tier_currency
      ) if component.calculation_type == "tiered"
      calculation_result = calculator.call(**calculation_attributes)
      return calculation_result if calculation_result.failure?

      success(build_component_result(selection, calculation_result.value, payer_result.value, amount))
    end

    def resolve_payer(component)
      selected = context.organizer_payer_selections[component.component_type]
      return success(component.charged_to) if selected.blank? || selected == component.charged_to
      return failure(error("payer_selection_forbidden")) unless component.organizer_payer_choice

      success(selected)
    end

    def resolve_basis(component)
      return success(nil) if component.basis_type.blank?

      value = context.basis_value(component.basis_type)
      return success(value) if value.present? || component.calculation_type == "tiered"

      failure(error("basis_unavailable"))
    rescue ArgumentError
      failure(error("basis_unavailable"))
    end

    def amount_for(component)
      return if component.fee_amounts.empty?

      component.fee_amounts.find { |amount| amount.currency == context.currency }
    end

    def calculator_for(component)
      strategy = CALCULATION_REGISTRY[component.calculation_type]
      return unless strategy

      strategy
    end

    def tier_metric_type(component)
      component.fee_tiers.first&.metric_type
    end

    def tier_metric_value(component)
      metric_type = tier_metric_type(component)
      return if metric_type.blank?

      context.metric_value(metric_type)
    rescue ArgumentError
      nil
    end

    def tier_currency
      context.settlement_currency.presence || context.currency
    end

    def build_component_result(selection, outcome, payer, amount)
      component = selection.component
      version = selection.version
      schedule = version.fee_schedule
      value = outcome.amount_minor
      Resolution::ComponentResult.new(
        component_type: component.component_type,
        label: component.label,
        currency: context.currency,
        amount_minor: value,
        signed_amount_minor: component.component_type == "platform_subsidy" ? -value : value,
        schedule_id: schedule.id,
        schedule_code: schedule.code,
        schedule_type: schedule.schedule_type,
        version_id: version.id,
        version_number: version.version,
        definition_digest: version.definition_digest,
        assignment_id: selection.assignment&.id,
        program_id: selection.assignment&.program_id,
        component_id: component.id,
        calculation_type: component.calculation_type,
        basis_type: component.basis_type,
        basis_minor: outcome.basis_minor,
        rate_bps: outcome.rate_bps,
        fixed_amount_minor: outcome.fixed_amount_minor || amount&.fixed_amount_minor,
        minimum_minor: outcome.minimum_minor || amount&.minimum_minor,
        maximum_minor: outcome.maximum_minor || amount&.maximum_minor,
        tier_position: outcome.tier_position,
        tier_metric_type: outcome.tier_metric_type,
        tier_metric_value: outcome.tier_metric_value,
        tier_window_type: outcome.tier_window_type,
        tier_starts_at_value: outcome.tier_starts_at_value,
        payer:,
        default_payer: component.charged_to,
        funder: component.funded_by,
        refund_policy: component.refund_policy,
        offset_component_type: component.offset_component_type,
        scope: scope_evidence(component),
        explanation: explanation(selection)
      )
    end

    def scope_evidence(component)
      Resolution::SelectComponent::SCOPE_ATTRIBUTES.index_with do |attribute|
        component.public_send(attribute)
      end
    end

    def explanation(selection)
      {
        source: selection.source.to_s,
        specificity: selection.specificity,
        matched_scope: selection.specificity.each_with_index.filter_map do |value, index|
          Resolution::SelectComponent::SCOPE_ATTRIBUTES[index].to_s if value == 1
        end
      }
    end

    def build_charge_result(component_results)
      # Subsidies remain separate negative adjustments; buyer and organizer
      # totals describe the undiscounted payer-facing charges only.
      Resolution::ChargeResult.new(
        currency: context.currency,
        settlement_currency: tier_currency,
        quoted_at: context.quoted_at,
        definition_signature: definition_signature(component_results),
        buyer_fee_total: component_results.sum do |component|
          component.component_type == "platform_subsidy" || component.payer != "buyer" ? 0 : component.amount_minor
        end,
        organizer_fee_total: component_results.sum do |component|
          component.component_type == "platform_subsidy" || component.payer != "organizer" ? 0 : component.amount_minor
        end,
        subsidy_total: component_results.sum do |component|
          component.component_type == "platform_subsidy" ? component.amount_minor : 0
        end,
        component_results:
      )
    end

    def definition_signature(component_results)
      definitions = component_results.map do |component|
        [ component.schedule_id, component.version_id, component.definition_digest ]
      end.sort_by { |definition| definition.map(&:to_s) }
      Digest::SHA256.hexdigest(JSON.generate(definitions))
    end

    def invalid_context?
      context.organization_id.blank? || context.currency.blank? || context.quoted_at.blank? ||
        !%w[primary resale].include?(context.sale_context) || !valid_currency?(context.currency)
    end

    def valid_currency?(currency)
      currency.match?(/\A[A-Z]{3}\z/)
    end

    def error(code)
      Core::BusinessError.new(
        I18n.t("commercial.resolution.errors.#{code}"),
        code:, status: :unprocessable_entity
      )
    end
  end
end
