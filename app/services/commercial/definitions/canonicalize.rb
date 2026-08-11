# frozen_string_literal: true

require "digest"
require "json"

module Commercial
  module Definitions
    class Canonicalize < Core::BaseService
      CanonicalDefinition = Data.define(:definition, :digest)

      def initialize(version:)
        @version = version
      end

      def call
        definition = deep_freeze(build_definition)
        digest = Digest::SHA256.hexdigest(JSON.generate(definition))

        success(CanonicalDefinition.new(definition:, digest:))
      end

      private

      attr_reader :version

      def build_definition
        {
          schedule_type: definition_version.fee_schedule.schedule_type,
          components: components.map { |component| component_definition(component) }
            .sort_by { |component| JSON.generate(component) }
        }
      end

      def definition_version
        @definition_version ||= if version.persisted?
          Commercial::FeeScheduleVersion
            .includes(:fee_schedule, fee_components: %i[fee_amounts fee_tiers])
            .find(version.id)
        else
          version
        end
      end

      def components
        definition_version.fee_components.to_a
      end

      def component_definition(component)
        {
          component_type: component.component_type,
          calculation_type: component.calculation_type,
          charged_to: component.charged_to,
          organizer_payer_choice: component.organizer_payer_choice,
          funded_by: component.funded_by,
          basis_type: component.basis_type,
          rate_bps: component.rate_bps,
          refund_policy: component.refund_policy,
          offset_component_type: component.offset_component_type,
          event_product_id: component.event_product_id,
          product_type: component.product_type,
          sale_context: component.sale_context,
          provider: component.provider,
          payment_method: component.payment_method,
          sales_channel: component.sales_channel,
          currency: component.currency,
          label: component.label,
          amounts: component.fee_amounts.to_a.sort_by(&:currency).map { |amount| amount_definition(amount) },
          tiers: component.fee_tiers.to_a.sort_by(&:position).map { |tier| tier_definition(tier) }
        }
      end

      def amount_definition(amount)
        {
          currency: amount.currency,
          fixed_amount_minor: amount.fixed_amount_minor,
          minimum_minor: amount.minimum_minor,
          maximum_minor: amount.maximum_minor
        }
      end

      def tier_definition(tier)
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

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end

        value.freeze
      end
    end
  end
end
