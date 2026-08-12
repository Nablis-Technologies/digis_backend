# frozen_string_literal: true

module Commercial
  # Serializes the organizer contract, deliberately omitting internal
  # commission, subsidy-budget, provider-cost, risk, and approval evidence.
  class OrganizationTermsSerializer < ActiveModel::Serializer
    attributes :organization_id, :current_terms, :scheduled_terms,
      :acceptance_history, :event_exceptions

    def current_terms
      safe_version(object.current_version)
    end

    def scheduled_terms
      safe_version(object.scheduled_version)
    end

    private

    def safe_version(version)
      return if version.blank?

      {
        id: version.id,
        status: version.status,
        effective_from: version.effective_from,
        effective_until: version.effective_until,
        acceptance_policy: version.acceptance_policy,
        legal_document_version_id: version.legal_document_version_id,
        components: version.fee_components.filter_map { |component| safe_component(component) }
      }
    end

    def safe_component(component)
      return if component.component_type.in?(%w[platform_commission platform_subsidy])

      {
        label: component.label,
        component_type: component.component_type,
        calculation_type: component.calculation_type,
        charged_to: component.charged_to,
        basis_type: component.basis_type,
        rate_bps: component.rate_bps,
        refund_policy: component.refund_policy,
        currency: component.currency,
        amounts: component.fee_amounts.map do |amount|
          {
            currency: amount.currency,
            fixed_amount_minor: amount.fixed_amount_minor,
            minimum_minor: amount.minimum_minor,
            maximum_minor: amount.maximum_minor
          }
        end,
        tiers: component.fee_tiers.map do |tier|
          {
            position: tier.position,
            metric_type: tier.metric_type,
            window_type: tier.window_type,
            currency: tier.currency,
            starts_at_value: tier.starts_at_value,
            rate_bps: tier.rate_bps,
            fixed_amount_minor: tier.fixed_amount_minor,
            minimum_minor: tier.minimum_minor,
            maximum_minor: tier.maximum_minor
          }
        end
      }
    end
  end
end
