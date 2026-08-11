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

      prepare_payer_selections(selections.value)
      volume_result = prepare_volume_state(selections.value)
      return failure(volume_result.error) if volume_result.failure?

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
      selected ||= @persisted_payer_selections[component.id]&.charged_to
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

      counter = volume_counter_for(component)
      return counter.value if counter

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
        **volume_evidence(component),
        payer:,
        default_payer: component.charged_to,
        funder: component.funded_by,
        refund_policy: component.refund_policy,
        offset_component_type: component.offset_component_type,
        scope: scope_evidence(component),
        explanation: explanation(selection)
      )
    end

    def prepare_payer_selections(selections)
      @persisted_payer_selections = if only_version || context.event_id.blank?
        {}
      else
        Commercial::EventPayerSelection.where(
          event_id: context.event_id,
          fee_component_id: selections.map { |selection| selection.component.id }
        ).index_by(&:fee_component_id)
      end
    end

    def prepare_volume_state(selections)
      @volume_dimensions = {}
      tiered_selections = selections.select { |selection| selection.component.calculation_type == "tiered" }
      tiered_selections.each do |selection|
        component = selection.component
        dimension = volume_dimension(component, selection)
        return failure(error("volume_window_unavailable")) unless dimension

        @volume_dimensions[component.id] = dimension
      end

      @volume_counters = if @volume_dimensions.empty?
        []
      else
        Commercial::VolumeCounter.where(
          fee_component_id: @volume_dimensions.keys,
          organization_id: context.organization_id
        ).to_a
      end
      success
    rescue ArgumentError
      failure(error("volume_window_unavailable"))
    end

    def volume_dimension(component, selection)
      metric_type = tier_metric_type(component)
      return if metric_type.blank?

      window_type = component.fee_tiers.first&.window_type
      return if window_type.blank?
      return if window_type == "event" && context.event_id.blank?

      window = Commercial::Volume::Window.resolve(
        window_type:, quoted_at: context.quoted_at,
        event: resolution_event,
        event_id: context.event_id,
        assignment: selection.assignment,
        version: selection.version,
        currency: metric_type == "accepted_gross" ? tier_currency : nil
      )
      {
        fee_component_id: component.id,
        organization_id: context.organization_id,
        event_id: window.event_id,
        metric_type:,
        window_type:,
        currency: window.currency,
        window_start_at: window.start_at,
        window_end_at: window.end_at
      }
    end

    def resolution_event
      return @resolution_event if defined?(@resolution_event)

      @resolution_event = Events::Event.includes(:event_dates).find_by(id: context.event_id)
    end

    def volume_counter_for(component)
      dimension = @volume_dimensions[component.id]
      return unless dimension

      @volume_counters.find do |counter|
        dimension.all? { |attribute, value| counter.public_send(attribute) == value }
      end
    end

    def volume_evidence(component)
      dimension = @volume_dimensions[component.id]
      counter = volume_counter_for(component)
      {
        volume_organization_id: dimension&.fetch(:organization_id),
        volume_event_id: dimension&.fetch(:event_id),
        volume_counter_id: counter&.id,
        volume_counter_value_before: counter&.value || tier_metric_value(component),
        volume_window_start_at: dimension&.fetch(:window_start_at),
        volume_window_end_at: dimension&.fetch(:window_end_at),
        volume_currency: dimension&.fetch(:currency)
      }
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
