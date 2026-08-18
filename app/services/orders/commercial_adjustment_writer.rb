# frozen_string_literal: true

module Orders
  # Projects one immutable Commercial::Resolution::ChargeResult into order
  # adjustments. The writer deliberately accepts the frozen value object only;
  # it never loads an active fee schedule or recalculates a component.
  class CommercialAdjustmentWriter < Core::BaseService
    COMPONENT_TYPES = {
      "platform_commission" => "platform_fee",
      "buyer_service_fee" => "service_fee",
      "processing_cost_recovery" => "processing_fee",
      "platform_subsidy" => "subsidy",
      "resale_platform_fee" => "resale_platform_fee"
    }.freeze

    def initialize(order:, order_item:, charge_result:)
      @order = order
      @order_item = order_item
      @charge_result = charge_result
    end

    def call
      return failure(error(:commercial_result_invalid, code: "commercial_result_invalid")) unless valid_input?

      adjustments = ActiveRecord::Base.transaction do
        @charge_result.component_results.map do |component|
          @order.order_adjustments.create!(attributes_for(component))
        end
      end
      success(adjustments)
    rescue ActiveRecord::RecordInvalid => exception
      failure(
        error(
          :commercial_adjustment_invalid,
          code: "commercial_adjustment_invalid",
          errors: exception.record.errors.to_hash
        )
      )
    rescue Core::Error => exception
      failure(exception)
    end

    private

    def valid_input?
      @order.is_a?(Orders::Order) &&
        @order_item.is_a?(Orders::OrderItem) &&
        @order_item.order_id == @order.id &&
        @charge_result.is_a?(Commercial::Resolution::ChargeResult) &&
        @charge_result.currency == @order.charge_currency
    end

    def attributes_for(component)
      type = COMPONENT_TYPES.fetch(component.component_type) do
        raise Core::Error, I18n.t("orders.checkout.errors.commercial_component_invalid")
      end
      {
        order_item: @order_item,
        type:,
        label: component.label,
        charged_to: component.payer,
        amount_minor: signed_amount_for(type, component),
        currency: component.currency,
        refund_policy: refund_policy_for(component),
        calculation_type: component.calculation_type,
        basis_type: component.basis_type,
        basis_minor: component.basis_minor,
        rate_bps: component.rate_bps,
        fixed_amount_minor: component.fixed_amount_minor,
        minimum_minor: component.minimum_minor,
        maximum_minor: component.maximum_minor,
        funded_by: component.funder,
        source_type: "Commercial::FeeComponent",
        source_id: component.component_id,
        resolution_evidence: resolution_evidence_for(component)
      }
    end

    def signed_amount_for(type, component)
      return -component.amount_minor if type == "subsidy"

      component.amount_minor
    end

    def refund_policy_for(component)
      return "nonrefundable" if component.payer == "organizer"

      component.refund_policy || "nonrefundable"
    end

    def resolution_evidence_for(component)
      scope = {
        schedule_id: component.schedule_id,
        schedule_code: component.schedule_code,
        schedule_type: component.schedule_type,
        version_id: component.version_id,
        version_number: component.version_number,
        definition_digest: component.definition_digest,
        component_id: component.component_id
      }
      scope.merge!(component.scope.to_h) if component.scope.respond_to?(:to_h)
      scope.merge!(version_id: component.version_id, component_id: component.component_id)

      evidence = { scope: }
      tier = {
        position: component.tier_position,
        metric_type: component.tier_metric_type,
        metric_value: component.tier_metric_value,
        window_type: component.tier_window_type,
        starts_at_value: component.tier_starts_at_value
      }.compact
      evidence[:tier] = tier if tier.present?

      window = {
        counter_id: component.volume_counter_id,
        counter_value_before: component.volume_counter_value_before,
        start_at: component.volume_window_start_at,
        end_at: component.volume_window_end_at,
        currency: component.volume_currency
      }.compact
      evidence[:window] = window if window.present?
      evidence[:rounding] = { mode: "half_up" }
      evidence[:explanation] = component.explanation if component.explanation.present?
      evidence.deep_stringify_keys
    end

    def error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.#{key}"),
        code:, status: :unprocessable_entity, errors:
      )
    end
  end
end
