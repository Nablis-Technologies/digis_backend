# frozen_string_literal: true

module Marketplace
  # Adapts trusted listing/order facts to Commercial's resale context. This
  # service deliberately owns no fee definitions or calculation rules; the
  # immutable Commercial result remains the sole source for seller-fee evidence.
  class ResolveResaleCharge < Core::BaseService
    def initialize(context:, gross_amount_minor:)
      @context = context
      @gross_amount_minor = gross_amount_minor
    end

    def call
      return failure(error("invalid_gross_amount")) unless valid_gross_amount?

      context = resale_context
      return failure(error("invalid_context")) unless context

      resolution = Commercial::ResolveCharges.call(context:)
      return failure(resolution.error) if resolution.failure?

      charge_result = resolution.value
      resale_fee = resale_fee_component(charge_result, context)
      return failure(error("resale_fee_unavailable")) unless resale_fee
      return failure(error("resale_fee_exceeds_gross")) if resale_fee.amount_minor > gross_amount_minor

      success(charge_result)
    end

    private

    attr_reader :context, :gross_amount_minor

    def valid_gross_amount?
      gross_amount_minor.is_a?(Integer) && gross_amount_minor.positive?
    end

    # The marketplace supplies the authoritative gross. Any caller-provided
    # resale basis or primary-sale scope is replaced before Commercial resolves.
    def resale_context
      return unless context.respond_to?(:to_h)

      Commercial::Resolution::Context.new(
        context.to_h.merge(
          sale_context: "resale",
          sales_channel: "resale",
          resale_acquisition_amount_minor: gross_amount_minor
        )
      )
    rescue ArgumentError, NoMethodError
      nil
    end

    def resale_fee_component(charge_result, resolved_context)
      return unless charge_result.is_a?(Commercial::Resolution::ChargeResult)

      components = charge_result.component_results.select do |component|
        component.component_type == "resale_platform_fee"
      end
      return unless components.one?

      component = components.first
      return unless valid_component?(component, resolved_context)

      component
    end

    def valid_component?(component, resolved_context)
      component.amount_minor.is_a?(Integer) && component.amount_minor >= 0 &&
        component.currency == resolved_context.currency &&
        component.signed_amount_minor == component.amount_minor &&
        component.component_id.present? && component.version_id.present? &&
        component.schedule_id.present? && component.definition_digest.present?
    end

    def error(code)
      Core::BusinessError.new(
        I18n.t("marketplace.resale_fee.errors.#{code}"),
        code:, status: :unprocessable_entity
      )
    end
  end
end
